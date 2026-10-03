;;; mu4e-llm-core.el --- Core LLM operations for mu4e-llm -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Dr. Sandeep Sadanandan

;; Author: Dr. Sandeep Sadanandan <sillyfellow@whybenormal.org>
;; URL: https://github.com/sillyfellow/mu4e-llm
;; Version: 0.1.0

;; This file is NOT part of GNU Emacs.

;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Core LLM operations: provider resolution, worker management, async calls.

;;; Code:

(require 'cl-lib)
(require 'mu4e-llm-config)

;; Forward declare llm functions to avoid byte-compile warnings
(declare-function llm-chat-streaming "llm")
(declare-function llm-cancel-request "llm")
(declare-function llm-make-chat-prompt "llm")
(declare-function mu4e-context-vars "mu4e-context")

;;; --- Worker Management ---

(cl-defstruct mu4e-llm--worker
  "Structure representing an active LLM operation."
  id              ; Unique identifier
  type            ; Operation type: summary, draft, translate, refine
  llm-request     ; The llm.el request object (for cancellation)
  message         ; The mu4e message being processed
  thread-id       ; Thread identifier
  buffer          ; Buffer where output is displayed
  active          ; Whether worker is still active (for late callbacks)
  callback        ; Completion callback
  metadata)       ; Additional operation-specific data

(defvar mu4e-llm--workers (make-hash-table :test 'equal)
  "Hash table of active workers, keyed by ID.")

(defvar mu4e-llm--worker-counter 0
  "Counter for generating unique worker IDs.")

;;; --- Cache Management ---

(defvar mu4e-llm--summary-cache (make-hash-table :test 'equal)
  "Cache for thread summaries.
Keys are \"message-id:message-count\", values are (timestamp . summary).")

(defun mu4e-llm--cache-key (message-id message-count)
  "Generate cache key from MESSAGE-ID and MESSAGE-COUNT."
  (format "%s:%d" message-id message-count))

(defun mu4e-llm--cache-get (key)
  "Get cached value for KEY if not expired."
  (when-let ((entry (gethash key mu4e-llm--summary-cache)))
    (let ((timestamp (car entry))
          (value (cdr entry)))
      (if (< (- (float-time) timestamp) mu4e-llm-cache-ttl)
          value
        (remhash key mu4e-llm--summary-cache)
        nil))))

(defun mu4e-llm--cache-set (key value)
  "Store VALUE in cache with KEY."
  (puthash key (cons (float-time) value) mu4e-llm--summary-cache))

;;;###autoload
(defun mu4e-llm-clear-cache ()
  "Clear the summary cache."
  (interactive)
  (clrhash mu4e-llm--summary-cache)
  (message "mu4e-llm: Cache cleared"))

;;; --- Provider Resolution ---

(defun mu4e-llm--get-provider ()
  "Get the LLM provider to use.
Uses `mu4e-llm-provider' if set, otherwise checks the variable named
by `mu4e-llm-provider-fallback-variable'."
  (or mu4e-llm-provider
      (and mu4e-llm-provider-fallback-variable
           (boundp mu4e-llm-provider-fallback-variable)
           (symbol-value mu4e-llm-provider-fallback-variable))
      (error "No LLM provider configured.
Set `mu4e-llm-provider' to an llm.el provider, e.g.:
  (setq mu4e-llm-provider (make-llm-openai :key \"your-key\"))")))

(defun mu4e-llm--operation-spec (type)
  "Return the `mu4e-llm-operation-models' entry for TYPE, or nil."
  (cdr (assq type mu4e-llm-operation-models)))

(defun mu4e-llm--provider-for (type)
  "Return the provider to use for operation TYPE.
When TYPE names a model in `mu4e-llm-operation-models', return a copy of
the resolved provider with that model.  The provider is shared with the
rest of the user\='s AI tools, so it is copied rather than modified."
  (let* ((base (mu4e-llm--get-provider))
         (model (plist-get (mu4e-llm--operation-spec type) :model)))
    (if (not model)
        base
      (let ((copy (copy-sequence base)))
        (setf (cl-struct-slot-value (type-of copy) 'chat-model copy) model)
        copy))))

(defun mu4e-llm--reasoning-params-for (type)
  "Return request parameters carrying the reasoning level for TYPE.
Nil when `mu4e-llm-operation-models' sets no level for TYPE."
  (let ((level (plist-get (mu4e-llm--operation-spec type) :reasoning)))
    (when level
      (list (cons "reasoning_effort" level)))))

;;; --- Worker Lifecycle ---

(defun mu4e-llm--create-worker (type message &optional callback metadata)
  "Create and register a new worker of TYPE for MESSAGE.
CALLBACK is called on completion with (success-p result).
METADATA is additional operation-specific data.
Returns the worker struct."
  (let* ((id (format "mu4e-llm-%d-%s" (cl-incf mu4e-llm--worker-counter) type))
         (worker (make-mu4e-llm--worker
                  :id id
                  :type type
                  :message message
                  :thread-id (when message
                               (plist-get message :message-id))
                  :active t
                  :callback callback
                  :metadata metadata)))
    (puthash id worker mu4e-llm--workers)
    worker))

(defun mu4e-llm--worker-finish (worker &optional result)
  "Mark WORKER as finished and invoke callback with RESULT."
  (when (mu4e-llm--worker-active worker)
    (setf (mu4e-llm--worker-active worker) nil)
    (remhash (mu4e-llm--worker-id worker) mu4e-llm--workers)
    (when-let ((callback (mu4e-llm--worker-callback worker)))
      (funcall callback t result))))

(defun mu4e-llm--worker-error (worker error-msg)
  "Mark WORKER as failed with ERROR-MSG and invoke callback."
  (when (mu4e-llm--worker-active worker)
    (setf (mu4e-llm--worker-active worker) nil)
    (remhash (mu4e-llm--worker-id worker) mu4e-llm--workers)
    (when-let ((callback (mu4e-llm--worker-callback worker)))
      (funcall callback nil error-msg))
    (message "mu4e-llm: Error - %s" error-msg)))

(defun mu4e-llm--abort-worker (worker)
  "Abort WORKER and cancel any pending LLM request."
  (when (mu4e-llm--worker-active worker)
    (setf (mu4e-llm--worker-active worker) nil)
    (when-let ((request (mu4e-llm--worker-llm-request worker)))
      (condition-case nil
          (llm-cancel-request request)
        (error nil)))
    (remhash (mu4e-llm--worker-id worker) mu4e-llm--workers)
    (message "mu4e-llm: Operation aborted")))

;;;###autoload
(defun mu4e-llm-abort ()
  "Abort all active mu4e-llm operations."
  (interactive)
  (let ((count 0))
    (maphash (lambda (_id worker)
               (mu4e-llm--abort-worker worker)
               (cl-incf count))
             mu4e-llm--workers)
    (if (> count 0)
        (message "mu4e-llm: Aborted %d operation(s)" count)
      (message "mu4e-llm: No active operations"))))

;;; --- LLM Chat Interface ---

(defun mu4e-llm--chat (worker prompt on-partial on-complete)
  "Execute streaming LLM chat for WORKER with PROMPT.
ON-PARTIAL is called with each text chunk during streaming.
ON-COMPLETE is called with final text when done.
Returns the llm request object."
  (unless (featurep 'llm)
    (require 'llm))
  (let* ((type (mu4e-llm--worker-type worker))
         (provider (mu4e-llm--provider-for type))
         (chat-prompt (llm-make-chat-prompt
                       prompt
                       :non-standard-params (mu4e-llm--reasoning-params-for type)))
         (accumulated "")
         (request
          (llm-chat-streaming
           provider
           chat-prompt
           ;; Partial callback
           (lambda (text)
             (when (mu4e-llm--worker-active worker)
               (setq accumulated text)
               (when on-partial
                 (funcall on-partial text))))
           ;; Done callback
           (lambda (_response)
             (when (mu4e-llm--worker-active worker)
               (when on-complete
                 (funcall on-complete accumulated))
               (mu4e-llm--worker-finish worker accumulated)))
           ;; Error callback.  llm.el calls this with an error type and a
           ;; message string, never an error object, so the message is
           ;; formatted directly rather than through
           ;; `error-message-string', which would signal on a string.
           (lambda (type err)
             (mu4e-llm--worker-error
              worker
              (format "LLM error (%s): %s" type err))))))
    (setf (mu4e-llm--worker-llm-request worker) request)
    request))

;;; --- Utility Functions ---

(defun mu4e-llm--user-identity ()
  "Get the current user's name and email from mu4e context."
  (let ((ctx (when (fboundp 'mu4e-context-current)
               (mu4e-context-current))))
    (cons (or (when ctx
                (cdr (assq 'user-full-name
                           (mu4e-context-vars ctx))))
              user-full-name
              "User")
          (or (when ctx
                (cdr (assq 'user-mail-address
                           (mu4e-context-vars ctx))))
              user-mail-address
              "user@example.com"))))

(defun mu4e-llm--active-workers ()
  "Return list of active workers."
  (let (workers)
    (maphash (lambda (_id worker)
               (when (mu4e-llm--worker-active worker)
                 (push worker workers)))
             mu4e-llm--workers)
    workers))

;;;###autoload
(defun mu4e-llm-status ()
  "Display status of active mu4e-llm operations."
  (interactive)
  (let ((workers (mu4e-llm--active-workers)))
    (if workers
        (message "mu4e-llm: %d active operation(s): %s"
                 (length workers)
                 (mapconcat (lambda (w)
                              (symbol-name (mu4e-llm--worker-type w)))
                            workers ", "))
      (message "mu4e-llm: No active operations"))))

(provide 'mu4e-llm-core)
;;; mu4e-llm-core.el ends here
