;;; mu4e-llm-test.el --- Tests for mu4e-llm -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Dr. Sandeep Sadanandan

;;; Commentary:
;; Unit tests for mu4e-llm pure functions.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Add parent directory to load-path for testing
(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." dir)))

(require 'mu4e-llm-config)
(require 'mu4e-llm-thread)
(require 'mu4e-llm-core)

;;; ==========================================================================
;;; Body Cleanup Tests (mu4e-llm-thread--clean-body)
;;; ==========================================================================

(ert-deftest mu4e-llm-test-clean-body-passthrough ()
  "Plain text should pass through unchanged."
  (should (equal "Hello world"
                 (mu4e-llm-thread--clean-body "Hello world"))))

(ert-deftest mu4e-llm-test-clean-body-removes-single-quote ()
  "Single level quotes should be removed."
  (should (equal "Hello"
                 (mu4e-llm-thread--clean-body "> quoted line\nHello"))))

(ert-deftest mu4e-llm-test-clean-body-removes-nested-quotes ()
  "Nested quotes should be removed."
  (should (equal "Response"
                 (mu4e-llm-thread--clean-body ">> deeply quoted\n> quoted\nResponse"))))

(ert-deftest mu4e-llm-test-clean-body-removes-gmail-quote-intro ()
  "Gmail-style 'On X wrote:' should be removed when followed by quotes."
  (let ((input "Thanks!\n\nOn Mon, Dec 23, 2024 at 10:00 AM John wrote:\n> old message"))
    (should (equal "Thanks!"
                   (mu4e-llm-thread--clean-body input)))))

(ert-deftest mu4e-llm-test-clean-body-removes-signature ()
  "Standard signature marker '-- ' should truncate content."
  (should (equal "Message body"
                 (mu4e-llm-thread--clean-body "Message body\n-- \nJohn Doe\nCompany Inc"))))

(ert-deftest mu4e-llm-test-clean-body-removes-mobile-signature ()
  "Mobile signatures should be removed."
  (should (equal "Quick reply"
                 (mu4e-llm-thread--clean-body "Quick reply\nSent from my iPhone"))))

(ert-deftest mu4e-llm-test-clean-body-removes-outlook-signature ()
  "Outlook mobile signatures should be removed."
  (should (equal "Reply here"
                 (mu4e-llm-thread--clean-body "Reply here\nGet Outlook for iOS"))))

(ert-deftest mu4e-llm-test-clean-body-collapses-blank-lines ()
  "Multiple blank lines should be collapsed to maximum two."
  (let ((input "First\n\n\n\n\nSecond"))
    (should (equal "First\n\nSecond"
                   (mu4e-llm-thread--clean-body input)))))

(ert-deftest mu4e-llm-test-clean-body-truncates-long-text ()
  "Long text should be truncated with indicator."
  (let* ((long-text (make-string 5000 ?x))
         (result (mu4e-llm-thread--clean-body long-text 100)))
    (should (= (length result) (+ 100 (length "\n[... truncated ...]"))))
    (should (string-suffix-p "[... truncated ...]" result))))

(ert-deftest mu4e-llm-test-clean-body-handles-nil ()
  "Nil input should return empty string."
  (should (equal "" (mu4e-llm-thread--clean-body nil))))

(ert-deftest mu4e-llm-test-clean-body-handles-empty ()
  "Empty input should return empty string."
  (should (equal "" (mu4e-llm-thread--clean-body ""))))

(ert-deftest mu4e-llm-test-clean-body-removes-german-quote ()
  "German emails with quoted lines should have quotes removed."
  ;; The '> ' quoted lines are removed; the intro line remains
  ;; (German intro pattern is defined but not actively filtered)
  (let ((input "Danke!\n\n> alte Nachricht\n> mehr zitiert"))
    (should (equal "Danke!"
                   (mu4e-llm-thread--clean-body input)))))

(ert-deftest mu4e-llm-test-clean-body-removes-original-message ()
  "Outlook 'Original Message' separator should be removed."
  ;; Pattern: ^-+\s-*Original Message\s-*-+$ - requires dashes on both ends
  (let ((input "My reply\n\n---------- Original Message ----------\n> Old content"))
    (should (equal "My reply"
                   (mu4e-llm-thread--clean-body input)))))

;;; ==========================================================================
;;; Address Formatting Tests (mu4e-llm-thread--format-address)
;;; ==========================================================================

(ert-deftest mu4e-llm-test-format-address-string ()
  "String addresses should pass through."
  (should (equal "test@example.com"
                 (mu4e-llm-thread--format-address "test@example.com"))))

(ert-deftest mu4e-llm-test-format-address-plist-full ()
  "Plist with name and email should format correctly."
  (should (equal "John Doe <john@example.com>"
                 (mu4e-llm-thread--format-address
                  '(:name "John Doe" :email "john@example.com")))))

(ert-deftest mu4e-llm-test-format-address-plist-email-only ()
  "Plist with only email should return email."
  (should (equal "john@example.com"
                 (mu4e-llm-thread--format-address
                  '(:email "john@example.com")))))

(ert-deftest mu4e-llm-test-format-address-cons-full ()
  "Old cons format (name . email) should work."
  (should (equal "Jane Doe <jane@example.com>"
                 (mu4e-llm-thread--format-address
                  '("Jane Doe" . "jane@example.com")))))

(ert-deftest mu4e-llm-test-format-address-cons-no-name ()
  "Cons with empty name should return just email."
  (should (equal "anon@example.com"
                 (mu4e-llm-thread--format-address
                  '("" . "anon@example.com")))))

(ert-deftest mu4e-llm-test-format-address-unknown ()
  "Unknown format should return 'unknown'."
  (should (equal "unknown"
                 (mu4e-llm-thread--format-address 12345))))

(ert-deftest mu4e-llm-test-format-addresses-list ()
  "List of addresses should be comma-separated."
  (should (equal "a@test.com, b@test.com"
                 (mu4e-llm-thread--format-addresses
                  '("a@test.com" "b@test.com")))))

;;; ==========================================================================
;;; Cache Tests (mu4e-llm--cache-*)
;;; ==========================================================================

(ert-deftest mu4e-llm-test-cache-key-generation ()
  "Cache key should combine message-id and count."
  (should (equal "msg123:5"
                 (mu4e-llm--cache-key "msg123" 5))))

(ert-deftest mu4e-llm-test-cache-set-and-get ()
  "Should be able to set and get cached values."
  (let ((mu4e-llm--summary-cache (make-hash-table :test 'equal))
        (mu4e-llm-cache-ttl 3600))
    (mu4e-llm--cache-set "test-key" "test-value")
    (should (equal "test-value"
                   (mu4e-llm--cache-get "test-key")))))

(ert-deftest mu4e-llm-test-cache-miss ()
  "Non-existent key should return nil."
  (let ((mu4e-llm--summary-cache (make-hash-table :test 'equal)))
    (should (null (mu4e-llm--cache-get "nonexistent")))))

(ert-deftest mu4e-llm-test-cache-expiry ()
  "Expired entries should return nil and be removed."
  (let ((mu4e-llm--summary-cache (make-hash-table :test 'equal))
        (mu4e-llm-cache-ttl 0))  ; Immediate expiry
    (mu4e-llm--cache-set "expire-key" "value")
    ;; Sleep briefly to ensure expiry
    (sleep-for 0.1)
    (should (null (mu4e-llm--cache-get "expire-key")))
    ;; Entry should be removed
    (should (null (gethash "expire-key" mu4e-llm--summary-cache)))))

;;; ==========================================================================
;;; Config Tests
;;; ==========================================================================

(ert-deftest mu4e-llm-test-config-defaults ()
  "Default config values should be sensible."
  (should (numberp mu4e-llm-temperature))
  (should (<= 0 mu4e-llm-temperature 1))
  (should (integerp mu4e-llm-max-tokens))
  (should (> mu4e-llm-max-tokens 0))
  (should (integerp mu4e-llm-max-thread-messages))
  (should (> mu4e-llm-max-thread-messages 0))
  (should (integerp mu4e-llm-cache-ttl))
  (should (> mu4e-llm-cache-ttl 0)))

(ert-deftest mu4e-llm-test-config-languages ()
  "Language list should have valid structure."
  (should (listp mu4e-llm-languages))
  (should (> (length mu4e-llm-languages) 0))
  (dolist (lang mu4e-llm-languages)
    (should (consp lang))
    (should (stringp (car lang)))
    (should (stringp (cdr lang)))))

(ert-deftest mu4e-llm-test-config-persona ()
  "Default persona should be valid."
  (should (memq mu4e-llm-draft-persona
                '(professional friendly formal concise))))

;;; ==========================================================================
;;; Worker Tests
;;; ==========================================================================

(ert-deftest mu4e-llm-test-worker-creation ()
  "Workers should be created with correct fields."
  (let ((mu4e-llm--workers (make-hash-table :test 'equal))
        (mu4e-llm--worker-counter 0))
    (let ((worker (mu4e-llm--create-worker 'summary nil)))
      (should (mu4e-llm--worker-p worker))
      (should (eq 'summary (mu4e-llm--worker-type worker)))
      (should (mu4e-llm--worker-active worker))
      (should (stringp (mu4e-llm--worker-id worker))))))

(ert-deftest mu4e-llm-test-worker-unique-ids ()
  "Each worker should have a unique ID."
  (let ((mu4e-llm--workers (make-hash-table :test 'equal))
        (mu4e-llm--worker-counter 0))
    (let ((w1 (mu4e-llm--create-worker 'summary nil))
          (w2 (mu4e-llm--create-worker 'draft nil)))
      (should-not (equal (mu4e-llm--worker-id w1)
                         (mu4e-llm--worker-id w2))))))

(ert-deftest mu4e-llm-test-worker-finish ()
  "Finishing a worker should deactivate it and remove from table."
  (let ((mu4e-llm--workers (make-hash-table :test 'equal))
        (mu4e-llm--worker-counter 0)
        (callback-called nil))
    (let ((worker (mu4e-llm--create-worker
                   'summary nil
                   (lambda (success result)
                     (setq callback-called (cons success result))))))
      (mu4e-llm--worker-finish worker "done")
      (should-not (mu4e-llm--worker-active worker))
      (should (null (gethash (mu4e-llm--worker-id worker)
                             mu4e-llm--workers)))
      (should (equal '(t . "done") callback-called)))))

;;; ==========================================================================
;;; Chat Tests (mu4e-llm--chat)
;;; ==========================================================================

;; These are the first tests here that stub a function.  `llm-chat-streaming'
;; and `llm-make-chat-prompt' are only declared in mu4e-llm-core, so they are
;; unbound unless llm is installed; `cl-letf' binds them either way.
;;
;; `mu4e-llm--chat' opens with (unless (featurep 'llm) (require 'llm)), which
;; fails when llm is absent.  `features' cannot be let-bound around that:
;; it is not a special variable, so under lexical binding the binding is
;; lexical and `featurep' keeps reading the global list.  Stub `require'
;; instead.  The stubbed body requires nothing else.

(defmacro mu4e-llm-test--with-stubbed-llm (streaming-fn &rest body)
  "Run BODY with `llm-chat-streaming' bound to STREAMING-FN.
`llm-make-chat-prompt' returns its argument unchanged, and `require' is a
no-op so no real llm is loaded."
  (declare (indent 1) (debug t))
  `(let ((mu4e-llm-provider 'test-provider))
     (cl-letf (((symbol-function 'require) (lambda (&rest _) nil))
               ((symbol-function 'llm-make-chat-prompt) (lambda (p &rest _) p))
               ((symbol-function 'llm-chat-streaming) ,streaming-fn))
       ,@body)))

(ert-deftest mu4e-llm-test-chat-error-callback-takes-two-arguments ()
  "llm.el calls the error callback with an error type and a message.
A one-argument callback signals `wrong-number-of-arguments' instead of
reporting the provider's message."
  (let ((mu4e-llm--workers (make-hash-table :test 'equal))
        (mu4e-llm--worker-counter 0)
        (reported nil))
    (mu4e-llm-test--with-stubbed-llm
        (lambda (_provider _prompt _partial _done errcb)
          (funcall errcb 'llm-http-error "rate limited")
          'fake-request)
      (let ((worker (mu4e-llm--create-worker
                     'summary nil
                     (lambda (success result) (setq reported (cons success result))))))
        (mu4e-llm--chat worker "prompt" nil nil)
        (should (equal nil (car reported)))
        (should (string-match-p "rate limited" (cdr reported)))))))

(ert-deftest mu4e-llm-test-chat-error-message-is-a-string ()
  "The second argument is a message, not an error object.
`error-message-string' on it signals `wrong-type-argument', so it must
not be used to format the report."
  (should-error (error-message-string "rate limited")
                :type 'wrong-type-argument))

(ert-deftest mu4e-llm-test-chat-error-ignored-when-worker-inactive ()
  "An error arriving after an abort should not reach the callback."
  (let ((mu4e-llm--workers (make-hash-table :test 'equal))
        (mu4e-llm--worker-counter 0)
        (reported nil))
    (mu4e-llm-test--with-stubbed-llm
        (lambda (_provider _prompt _partial _done errcb)
          (funcall errcb 'llm-http-error "too late")
          'fake-request)
      (let ((worker (mu4e-llm--create-worker
                     'summary nil
                     (lambda (success result) (setq reported (cons success result))))))
        (setf (mu4e-llm--worker-active worker) nil)
        (mu4e-llm--chat worker "prompt" nil nil)
        (should (null reported))))))

(ert-deftest mu4e-llm-test-chat-success-path ()
  "A successful run reaches on-partial and on-complete, and stores the request."
  (let ((mu4e-llm--workers (make-hash-table :test 'equal))
        (mu4e-llm--worker-counter 0)
        (partials nil)
        (completed nil))
    (mu4e-llm-test--with-stubbed-llm
        (lambda (_provider _prompt partial done _errcb)
          (funcall partial "par")
          (funcall partial "partial text")
          (funcall done "ignored")
          'fake-request)
      (let ((worker (mu4e-llm--create-worker 'summary nil)))
        (mu4e-llm--chat worker "prompt"
                        (lambda (text) (push text partials))
                        (lambda (text) (setq completed text)))
        (should (equal '("partial text" "par") partials))
        (should (equal "partial text" completed))
        (should (eq 'fake-request (mu4e-llm--worker-llm-request worker)))))))

(ert-deftest mu4e-llm-test-chat-passes-provider-and-prompt ()
  "The resolved provider and the prompt reach `llm-chat-streaming'."
  (let ((mu4e-llm--workers (make-hash-table :test 'equal))
        (mu4e-llm--worker-counter 0)
        (seen nil))
    (mu4e-llm-test--with-stubbed-llm
        (lambda (provider prompt &rest _) (setq seen (cons provider prompt)) nil)
      (mu4e-llm--chat (mu4e-llm--create-worker 'summary nil) "the prompt" nil nil)
      (should (eq 'test-provider (car seen)))
      (should (equal "the prompt" (cdr seen))))))

(ert-deftest mu4e-llm-test-chat-streaming-contract ()
  "Pin the real `llm-chat-streaming' arity, when llm is installed.
The stubs above pin this package's assumption about llm.el rather than
llm.el itself.  Four arguments is too few; five reaches the nil-provider
method and signals something else.  `func-arity' cannot be used here
because `llm-chat-streaming' is a generic and reports (1 . many)."
  ;; The Makefile runs emacs with -Q, so package.el is not initialised and
  ;; an installed llm is not yet on the load path.  Try that before giving
  ;; up, or this test would skip everywhere, including CI.
  (skip-unless (or (require 'llm nil t)
                   (progn (require 'package)
                          (package-initialize)
                          (require 'llm nil t))))
  (let ((cb (lambda (&rest _) nil)))
    (should-error (llm-chat-streaming nil "p" cb cb)
                  :type 'wrong-number-of-arguments)
    (let ((err (should-error (llm-chat-streaming nil "p" cb cb cb))))
      (should-not (eq (car err) 'wrong-number-of-arguments)))))

(provide 'mu4e-llm-test)
;;; mu4e-llm-test.el ends here
