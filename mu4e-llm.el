;;; mu4e-llm.el --- AI-powered email assistance for mu4e -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Dr. Sandeep Sadanandan

;; Author: Dr. Sandeep Sadanandan <sillyfellow@whybenormal.org>
;; URL: https://github.com/sillyfellow/mu4e-llm
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (llm "0.17"))
;; Keywords: mail, convenience

;; This file is NOT part of GNU Emacs.

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; mu4e-llm provides AI-powered email assistance for mu4e using LLM providers
;; via the llm.el library.
;;
;; Features:
;; - Thread summarization (standard and executive)
;; - Smart reply drafting with iterative refinement
;; - Email translation
;;
;; Quick start:
;;   (require 'mu4e-llm)
;;   (mu4e-llm-setup)
;;
;; Then in mu4e, use C-c a e prefix for AI commands:
;;   C-c a e s - Summarize thread
;;   C-c a e r - Generate smart reply
;;   C-c a e t - Translate message

;;; Code:

(require 'cl-lib)
(declare-function cl-struct-slot-value "cl-macs" (struct-type slot-name inst))
(require 'mu4e-llm-config)
(require 'mu4e-llm-core)

;; These will be loaded when needed
(declare-function mu4e-llm-summarize "mu4e-llm-summary")
(declare-function mu4e-llm-summarize-executive "mu4e-llm-summary")
(declare-function mu4e-llm-draft-reply "mu4e-llm-draft")
(declare-function mu4e-llm-draft-refine "mu4e-llm-draft")
(declare-function mu4e-llm-draft-compose "mu4e-llm-draft")
(declare-function mu4e-llm-translate-message "mu4e-llm-translate")
(declare-function mu4e-llm-translate-thread "mu4e-llm-translate")

;;; --- Keymap ---

(defvar mu4e-llm-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'mu4e-llm-summarize)
    (define-key map (kbd "S") #'mu4e-llm-summarize-executive)
    (define-key map (kbd "r") #'mu4e-llm-draft-reply)
    (define-key map (kbd "R") #'mu4e-llm-draft-refine)
    (define-key map (kbd "n") #'mu4e-llm-draft-compose)
    (define-key map (kbd "t") #'mu4e-llm-translate-message)
    (define-key map (kbd "T") #'mu4e-llm-translate-thread)
    (define-key map (kbd "a") #'mu4e-llm-abort)
    (define-key map (kbd "?") #'mu4e-llm-help)
    map)
  "Keymap for mu4e-llm commands.
Bound to the prefix specified by `mu4e-llm-keymap-prefix'.")

;;; --- Minor Mode ---

(defvar mu4e-llm-mode-map
  (make-sparse-keymap)
  "Keymap for `mu4e-llm-mode'.
The actual keybinding is set up by `mu4e-llm-setup' based on
`mu4e-llm-keymap-prefix'.")

;;;###autoload
(define-minor-mode mu4e-llm-mode
  "Minor mode providing AI assistance for mu4e.
\\{mu4e-llm-mode-map}"
  :lighter " LLM"
  :keymap mu4e-llm-mode-map
  :group 'mu4e-llm)

;;; --- Help ---

(defun mu4e-llm--help-text ()
  "Return the help text, naming the prefix actually in use."
  (format
   "mu4e-llm - AI-powered email assistance

Keybindings (%s prefix in mu4e):
  s   Summarize thread
  S   Executive summary (brief)
  r   Generate smart reply
  R   Refine current draft
  n   Compose new email with AI
  t   Translate message
  T   Translate thread
  a   Abort current operation
  ?   Show this help

In draft buffer:
  C-c C-r   Refine with instruction
  C-c C-s   Shorten
  C-c C-p   Make more polite
  C-c C-f   Finalize (open in compose)
  C-c C-k   Cancel

Current provider: %s"
   (or mu4e-llm-keymap-prefix "M-x mu4e-llm-")
   (condition-case nil
       (let* ((provider (mu4e-llm--get-provider))
              (type-name (replace-regexp-in-string
                          "^llm-" ""
                          (symbol-name (type-of provider))))
              (model (ignore-errors
                       (cl-struct-slot-value
                        (type-of provider) 'chat-model provider))))
         (if model
             (format "%s (%s)" type-name model)
           type-name))
     (error "Not configured"))))

(defun mu4e-llm-help ()
  "Display help for mu4e-llm commands."
  (interactive)
  (message "%s" (mu4e-llm--help-text)))

;;; --- Setup ---

(defun mu4e-llm--setup-keybindings ()
  "Set up keybindings in current mu4e buffer.
Called from mode hooks to ensure keymaps are available."
  (when (and mu4e-llm-keymap-prefix (current-local-map))
    (define-key (current-local-map) (kbd mu4e-llm-keymap-prefix) mu4e-llm-map)))

;;;###autoload
(defun mu4e-llm-setup ()
  "Initialize mu4e-llm with keybindings in mu4e modes.
Keybindings are controlled by `mu4e-llm-keymap-prefix'.
If set to nil, no automatic keybindings are created."
  (interactive)
  ;; Hang the commands under a shared prefix map, when one is configured
  ;; and actually exists.  This used to be derived by matching the prefix
  ;; against "C-c a", which made the two inseparable and refused any other
  ;; prefix shape.
  (when (and mu4e-llm-parent-keymap
             mu4e-llm-parent-keymap-suffix
             (boundp mu4e-llm-parent-keymap)
             (keymapp (symbol-value mu4e-llm-parent-keymap)))
    (define-key (symbol-value mu4e-llm-parent-keymap)
                (kbd mu4e-llm-parent-keymap-suffix)
                mu4e-llm-map))
  (when mu4e-llm-keymap-prefix
    (define-key mu4e-llm-mode-map (kbd mu4e-llm-keymap-prefix) mu4e-llm-map))
  ;; Add hooks for mu4e modes (safe to call before mu4e loads)
  (add-hook 'mu4e-headers-mode-hook #'mu4e-llm-mode)
  (add-hook 'mu4e-view-mode-hook #'mu4e-llm-mode)
  (add-hook 'mu4e-headers-mode-hook #'mu4e-llm--setup-keybindings)
  (add-hook 'mu4e-view-mode-hook #'mu4e-llm--setup-keybindings)
  (message "mu4e-llm initialized. Use %s for AI commands."
           (or mu4e-llm-keymap-prefix "M-x mu4e-llm-*")))

;;; --- Autoloads for lazy loading ---

;; These are defined in their respective modules and will be autoloaded
(autoload 'mu4e-llm-summarize "mu4e-llm-summary"
  "Summarize the current email thread." t)
(autoload 'mu4e-llm-summarize-executive "mu4e-llm-summary"
  "Generate a brief executive summary of the current thread." t)
(autoload 'mu4e-llm-draft-reply "mu4e-llm-draft"
  "Generate a smart reply to the current email." t)
(autoload 'mu4e-llm-draft-refine "mu4e-llm-draft"
  "Refine the current draft with a custom instruction." t)
(autoload 'mu4e-llm-draft-compose "mu4e-llm-draft"
  "Compose a new email based on instructions." t)
(autoload 'mu4e-llm-translate-message "mu4e-llm-translate"
  "Translate the current email message." t)
(autoload 'mu4e-llm-translate-thread "mu4e-llm-translate"
  "Translate the entire email thread." t)

(provide 'mu4e-llm)
;;; mu4e-llm.el ends here
