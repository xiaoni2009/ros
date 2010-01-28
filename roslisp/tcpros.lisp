;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Software License Agreement (BSD License)
;; 
;; Copyright (c) 2008, Willow Garage, Inc.
;; All rights reserved.
;;
;; Redistribution and use in source and binary forms, with 
;; or without modification, are permitted provided that the 
;; following conditions are met:
;;
;;  * Redistributions of source code must retain the above 
;;    copyright notice, this list of conditions and the 
;;    following disclaimer.
;;  * Redistributions in binary form must reproduce the 
;;    above copyright notice, this list of conditions and 
;;    the following disclaimer in the documentation and/or 
;;    other materials provided with the distribution.
;;  * Neither the name of Willow Garage, Inc. nor the names 
;;    of its contributors may be used to endorse or promote 
;;    products derived from this software without specific 
;;    prior written permission.
;; 
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND 
;; CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED 
;; WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
;; PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
;; COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, 
;; INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, 
;; PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
;; CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE 
;; OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS 
;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH 
;; DAMAGE.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(in-package roslisp)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utility
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro bind-from-header (bindings header &body body)
  "Simplify binding a bunch of fields from a header and signaling a condition if there's a problem"
  (let ((h (gensym)))
    `(let ((,h ,header))
       (let ,(mapcar #'(lambda (binding) (list (first binding) `(lookup-alist ,h ,(second binding)))) bindings)
	 ,@body))))

(define-condition malformed-tcpros-header (error)
  ((msg :accessor msg :initarg :msg)))

(defun tcpros-header-assert (condition str &rest args)
  (unless condition
    (error 'malformed-tcpros-header :msg (apply #'format nil str args))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ROS Node connection server
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ros-node-tcp-server (port)
  "Return a passive socket that listens for connections on the given port.  The handler for incoming connections is (the function returned by) server-connection-handler."
  (let ((socket (make-instance 'inet-socket :type :stream :protocol :tcp))
	(ip-address #(0 0 0 0)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (socket-bind socket ip-address port)
    (ros-debug (roslisp tcp) "Bound tcp listener ~a" socket)
    (socket-listen socket 5)
    (sb-sys:add-fd-handler (socket-file-descriptor socket)
			   :input (server-connection-handler socket))
    socket))


(defun server-connection-handler (socket)
  "Return the handler for incoming connections to this socket.  The handler accepts the connection, and decides whether its a topic or service depending on whether the header has a topic field, and passes it to handle-topic-connection or handle-service connection as appropriate.  If the header cannot be parsed or lacks the necessary fields, send an error header across the socket, close it, and print a warning message on this side."
  #'(lambda (fd)
      (declare (ignore fd))
      (let* ((connection (socket-accept socket))
	     (stream (socket-make-stream connection :element-type '(unsigned-byte 8) :output t :input t :buffering :none)))
	(ros-debug (roslisp tcp) "Accepted TCP connection ~a" connection)
	
	(mvbind (header parse-error) (ignore-errors (parse-tcpros-header stream))
	  (handler-case
	      (cond
		((null header)
		 (ros-info (roslisp tcp) "Ignoring connection attempt due to error parsing header: '~a'" parse-error)
		 (socket-close connection))
		((equal (cdr (assoc "probe" header :test #'equal)) "1")
		 (socket-close connection))
		((assoc "topic" header :test #'equal)
		 (handle-topic-connection header connection stream))
		((assoc "service" header :test #'equal)
		 (handle-service-connection header connection stream)))
	    (malformed-tcpros-header (c)
	      (send-tcpros-header stream "error" (msg c))
	      (warn "Connection server received error ~a when trying to parse header ~a.  Ignoring this connection attempt." (msg c) header)
	      (socket-close connection))
	    (stream-error (c)
	      (warn "Connection failed unexpectedly. Error: ~a." c)
	      (ignore-errors
		(socket-close connection))))))))




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Topics
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defun handle-topic-connection (header connection stream)
  "Handle topic connection by checking md5 sum, sending back a response header, then adding this socket to the publication list for this topic."
  (bind-from-header ((topic "topic") (md5 "md5sum")) header
    (let ((pub (gethash topic *publications*)))
      (tcpros-header-assert pub "unknown-topic")
      (let ((my-md5 (string-downcase (format-md5 (md5sum topic)))))
	(tcpros-header-assert (or (equal md5 "*") (equal md5 my-md5)) "md5sums do not match: ~a vs ~a" md5 my-md5)
	
	;; Now we must send back the response
	(send-tcpros-header stream 
			    "type" (ros-datatype topic)
			    "caller-id" *ros-node-name*
			    "message_definition"  (message-definition topic)
			    "latching" (if (is-latching pub) "1" "0")
			    "md5sum" my-md5))
      
      ;; Add this subscription to the list for the topic
      (let ((sub (make-subscriber-connection :subscriber-socket connection :subscriber-stream stream)))
	(ros-debug (roslisp tcp) "~&Adding ~a to ~a for topic ~a" sub pub topic)
	(push sub (subscriber-connections pub))

	(when (and (is-latching pub) (last-message pub))
	  (ros-debug (roslisp tcp) "~&Resending latched message to new subscriber")
	  (tcpros-write (last-message pub) stream))))))




(defun setup-tcpros-subscription (hostname port topic)
  "Connect to the publisher at the given address and do the header exchange, then start a thread that will deserialize messages onto the queue for this topic."
  (check-type hostname string)

  (mvbind (str connection) (tcp-connect hostname port)
    (ros-debug (roslisp tcp) "~&Successfully connected to ~a:~a for topic ~a" hostname port topic)
    (handler-case

	(mvbind (sub known) (gethash topic *subscriptions*)
	  (assert known nil "Topic ~a unknown.  This error should have been caught earlier!" topic)
	  (let ((buffer (buffer sub))
		(topic-class-name (get-topic-class-name topic)))

	    ;; Send header and receive response
	    (send-tcpros-header str 
				"topic" topic 
				"md5sum" (string-downcase (format-md5 (md5sum topic))) 
				"type" (ros-datatype topic)
				"callerid" (fully-qualified-name *ros-node-name*))
	    (let ((response (parse-tcpros-header str)))

	      (when (assoc "error" response :test #'equal)
		(roslisp-error "During TCPROS handshake, publisher sent error message ~a" (cdr (assoc "error" response :test #'equal))))

	      ;; TODO need to do something with the response, handle AnyMsg (see tcpros.py)

	      ;; Spawn a dedicated thread to deserialize messages off the socket onto the queue
	      (sb-thread:make-thread
	       #'(lambda ()
		   (block thread-block
		   (unwind-protect
			(handler-bind
			    ((error #'(lambda (c)
					(unless *break-on-socket-errors*
					  (ros-info (roslisp tcp) "Received error ~a when reading connection to ~a:~a on topic ~a.  Connection terminated." c hostname port topic)
					  (return-from thread-block nil)))))
					  
					    
			  (loop
			     (unless (eq *node-status* :running)
			       (error "Node status is ~a" *node-status*))

			     ;; Read length (ignored)
			     (dotimes (i 4)
			       (read-byte str))

			     (let ((msg (deserialize topic-class-name str)))

			       (let ((num-dropped (enqueue msg buffer)))
				 (ros-info (roslisp tcp) (> num-dropped 0) "Dropped ~a messages on topic ~a" num-dropped topic)))))
		     
		     ;; Always close the connection before leaving the thread
		     (socket-close connection))))
	       :name (format nil "Roslisp thread for subscription to topic ~a published from ~a:~a" 
			     topic hostname port)
	       ))))

      (malformed-tcpros-header (c)
	(send-tcpros-header str "error" (msg c))
	(socket-close connection)
	(error c)))))
  



(defun tcpros-write (msg str)
  (or
   (unless (gethash str *broken-socket-streams*)
     (handler-case
	 (handler-bind
	     ((type-error #'invoke-debugger))
	   (serialize-int (serialization-length msg) str)
	   (serialize msg str)

	   ;; Technically, force-output isn't supposed to be called on binary streams...
	   (force-output str)
	   1 ;; Returns number of messages written 
	   )
       (error (c)
	 (ros-info (roslisp tcp) "Received error ~a when writing to ~a.  Skipping from now on." c str)
	 (setf (gethash str *broken-socket-streams*) t)
	 0)))
   0))





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Services
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun handle-service-connection (header connection stream)
  "Handle service connection.  For now, we assume a single request, which is processed immediately in this thread."
  (bind-from-header ((md5 "md5sum") (service-name "service")) header
    (let* ((service (gethash service-name *services*))
	   (my-md5 (string-downcase (service-md5 service))))
      (tcpros-header-assert service "Unknown service")
      (tcpros-header-assert (or (equal md5 "*") (equal md5 my-md5)) "md5 sums don't match: ~a vs ~a" md5 my-md5)
      (send-tcpros-header stream "md5sum" my-md5 "callerid" *ros-node-name*
			  "type" (service-ros-type service)
			  "request_type" (service-request-ros-type service) 
			  "response_type" (service-response-ros-type service))
      (handle-single-service-request stream connection (service-request-class service) 
				     (service-callback service)))))





(defun handle-single-service-request (stream connection request-class-name callback)
  ;; Read length
  (dotimes (i 4)
    (read-byte stream))
  (let* ((msg (deserialize request-class-name stream))
	 (response (funcall callback msg)))
    (unwind-protect
	 (progn
	   (write-byte 1 stream)
	   (serialize-int (serialization-length response) stream)
	   (serialize response stream)
	   (force-output stream))
      (socket-close connection))))
    




(defun tcpros-call-service (hostname port service-name req response-type)
  (check-type hostname string)
  (mvbind (str socket) (tcp-connect hostname port)
    (unwind-protect
	 (progn
	   (send-tcpros-header str "service" service-name "md5sum" (string-downcase (format-md5 (md5sum (class-name (class-of req))))) "callerid" *ros-node-name*)
	   (parse-tcpros-header str)
	   (tcpros-write req str)
	   (let ((ok-byte (read-byte str)))
	     (unless (eq ok-byte 1)
	       (roslisp-error "service-call to ~a:~a with request ~a failed" hostname port req))
	     (let ((len (deserialize-int str)))
	       (declare (ignore len))
	       (deserialize response-type str))))
      (socket-close socket))))


	  


    
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun send-tcpros-header (str &rest args)
  (assert (evenp (length args)) nil "send-tcpros-header received odd number of arguments ~a" args)
  (let ((l args)
	(key-value-pairs nil)
	(total-length 0))

    (while l
      (let ((next-pair (format nil "~a=~a" (pop l) (pop l))))
	(incf total-length (+ 4 (length next-pair))) ;; 4 for the 4-byte length at the beginning
	(push next-pair key-value-pairs)))

    (serialize-int total-length str)
    (dolist (pair key-value-pairs)
      (serialize-string pair str)))
  (force-output str))


(defun parse-tcpros-header (str)
  (let ((remaining-length (deserialize-int str))
	(key-value-pairs nil))
    (while (> remaining-length 0)
      (let ((field-string (deserialize-string str)))
	(decf remaining-length (+ 4 (length field-string))) ;; 4 for the length at the beginning
	(unless(>= remaining-length 0) 
	  (roslisp-error "Error parsing tcpros header: header length and field lengths didn't match"))
	
	(push (parse-header-field field-string) key-value-pairs)
	))
    key-value-pairs))

(defun parse-header-field (field-string)
  (let ((first-equal-sign-pos (position #\= field-string)))
    (if first-equal-sign-pos
	(cons (subseq field-string 0 first-equal-sign-pos)
	      (subseq field-string (1+ first-equal-sign-pos)))
	(roslisp-error "Error parsing tcpros header field ~a: did not contain an '='"
		       field-string))))


(defun lookup-alist (l key)
  (let ((pair (assoc key l :test #'equal)))
    (unless pair
      (error 'malformed-tcpros-header :msg (format nil "Could not find key ~a in ~a" key l)))
    (cdr pair)))


(defun format-md5 (md5)
  (format nil "~32,'0x" md5))
