;;; kubernetes-services.el --- Rendering for Kubernetes services.  -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:

(require 'dash)

(require 'kubernetes-kubectl)
(require 'kubernetes-modes)
(require 'kubernetes-state)
(require 'kubernetes-utils)
(require 'kubernetes-yaml)


;; Component

(defun kubernetes-services--format-details (service)
  (-let ((detail
          (lambda (key value)
            (when value
              `(key-value 15 ,key ,value))))

         (format-ports
          (-lambda ((&alist 'name name 'port port 'protocol prot))
            (concat (when name (format "%s:" name))
                    (number-to-string port) "/" prot)))

         ((&alist 'metadata (&alist 'namespace ns
                                    'creationTimestamp created-time)
                  'spec (&alist 'clusterIP internal-ip
                                'externalIPs ips
                                'ports ports))
          service))
    (-non-nil (list (funcall detail "Namespace" ns)
                    (funcall detail "Created" created-time)
                    (funcall detail "Internal IP" internal-ip)
                    (when-let (ips (append ips nil))
                      (funcall detail "External IPs" (string-join ips ", ")))
                    (when-let (ports (append ports nil))
                      (funcall detail "Ports" (string-join (-map format-ports ports) ", ")))))))

(defun kubernetes-services--format-line (state service)
  (-let* ((current-time (kubernetes-state-current-time state))
          (pending-deletion (kubernetes-state-services-pending-deletion state))
          (marked-services (kubernetes-state-marked-services state))
          ((&alist 'metadata (&alist 'name name 'creationTimestamp created-time)
                   'spec (&alist 'clusterIP internal-ip
                                 'externalIPs external-ips))
           service)
          (line `(line ,(concat
                         ;; Name
                         (format "%-30s " (kubernetes-utils-ellipsize name 30))

                         ;; Internal IP
                         (propertize (format "%15s " internal-ip) 'face 'magit-dimmed)

                         ;; External IP
                         (let ((ips (append external-ips nil)))
                           (propertize (format "%15s " (or (car ips) "")) 'face 'magit-dimmed))

                         ;; Age
                         (let ((start (apply #'encode-time (kubernetes-utils-parse-utc-timestamp created-time))))
                           (propertize (format "%6s" (kubernetes-utils-time-diff-string start current-time))
                                       'face 'magit-dimmed))))))
    `(nav-prop (:service-name ,name)
               (copy-prop ,name
                          ,(cond
                            ((member name pending-deletion)
                             `(propertize (face kubernetes-pending-deletion) ,line))
                            ((member name marked-services)
                             `(mark-for-delete ,line))
                            (t
                             line))))))

(defun kubernetes-services-render (state &optional hidden)
  (-let* (((services-response &as &alist 'items services) (kubernetes-state-services state))
          (services (append services nil))
          (column-heading (propertize (format "%-30s %15s %15s %6s" "Name" "Internal IP" "External IP" "Age") 'face 'magit-section-heading)))
    `(section (services-container ,hidden)
              ,(cond

                ;; If the state is set and there are no services, write "None".
                ((and services-response (null services))
                 `((heading ,(concat (propertize "Services" 'face 'magit-header-line) " (0)"))
                   (indent
                    (section (services-list nil)
                             (propertize (face magit-dimmed) (line "None."))))))

                ;; If there are services, write sections for each service.
                (services
                 (let ((make-entry
                        (lambda (it)
                          `(section (,(intern (kubernetes-state-resource-name it)) t)
                                    (heading ,(kubernetes-services--format-line state it))
                                    (indent
                                     (section (details nil)
                                              ,@(kubernetes-services--format-details it)
                                              (padding)))))))
                   `((heading ,(concat (propertize "Services" 'face 'magit-header-line) " " (format "(%s)" (length services))))
                     (indent
                      (line ,column-heading)
                      ,@(-map make-entry services)))))

                ;; If there's no state, assume requests are in progress.
                (t
                 `((heading "Services")
                   (indent
                    (line ,column-heading)
                    (section (services-list nil)
                             (propertize (face kubernetes-progress-indicator) (line "Fetching...")))))))
              (padding))))


;; Requests and state management

(defun kubernetes-services-refresh (&optional interactive)
  (unless (kubernetes-process-poll-services-process-live-p)
    (kubernetes-process-set-poll-services-process
     (kubernetes-kubectl-get-services kubernetes-default-props
                                      (kubernetes-state)
                                      (lambda (response)
                                        (kubernetes-state-update-services response)
                                        (when interactive
                                          (message "Updated services.")))
                                      (lambda ()
                                        (kubernetes-process-release-poll-services-process))))))

(defun kubernetes-services-delete-marked (state)
  (let ((names (kubernetes-state-marked-services state)))
    (dolist (name names)
      (kubernetes-state-delete-service name)
      (kubernetes-kubectl-delete-service kubernetes-default-props state name
                                         (lambda (_)
                                           (message "Deleting service %s succeeded." name))
                                         (lambda (_)
                                           (message "Deleting service %s failed" name)
                                           (kubernetes-state-mark-service name))))
    (kubernetes-state-trigger-redraw)))


;; Displaying services

(defun kubernetes-services--read-name (state)
  "Read a service name from the user.

STATE is the current application state.

Update the service state if it not set yet."
  (-let* (((&alist 'items services)
           (or (kubernetes-state-services state)
               (progn
                 (message "Getting services...")
                 (let ((response (kubernetes-kubectl-await-on-async kubernetes-default-props state #'kubernetes-kubectl-get-services)))
                   (kubernetes-state-update-services response)
                   response))))
          (services (append services nil))
          (names (-map #'kubernetes-state-resource-name services)))
    (completing-read "Service: " names nil t)))

;;;###autoload
(defun kubernetes-display-service (service-name state)
  "Display information for a service in a new window.

STATE is the current application state.

SERVICE-NAME is the name of the service to display."
  (interactive (let ((state (kubernetes-state)))
                 (list (kubernetes-services--read-name state) state)))
  (if-let (service (kubernetes-state-lookup-service service-name state))
      (select-window
       (display-buffer
        (kubernetes-yaml-make-buffer kubernetes-display-service-buffer-name service)))
    (error "Unknown service: %s" service-name)))


(provide 'kubernetes-services)

;;; kubernetes-services.el ends here