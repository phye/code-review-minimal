;;; code-review-minimal-overlay.el --- Comment overlays and input overlay -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review

;;; Commentary:
;;
;; Comment overlay rendering, input overlay, and overlay navigation helpers
;; for code-review-minimal.
;;
;; Public API (called from code-review-minimal.el):
;;   Buffer-local state:
;;     `code-review-minimal--overlays'
;;     `code-review-minimal--input-overlay'
;;     `code-review-minimal--input-prompt-end'
;;   Overlay management:
;;     `code-review-minimal--clear-overlays'
;;     `code-review-minimal--insert-discussion-overlay'
;;   Input overlay:
;;     `code-review-minimal--open-input-overlay'
;;     `code-review-minimal--close-input-overlay'
;;     `code-review-minimal--cancel-comment'
;;     `code-review-minimal--submit-comment'
;;     `code-review-minimal-input-mode'
;;   Navigation:
;;     `code-review-minimal--overlay-at-point'
;;     `code-review-minimal--sorted-overlay-positions'
;;
;; Faces are defined in code-review-minimal-custom.el.

;;; Code:

(require 'cl-lib)
(require 'code-review-minimal-custom)
(require 'code-review-minimal-backend)

;; Forward declarations for dispatch functions defined in code-review-minimal.el.
;; These are called at runtime (never at load time), so there is no circular
;; dependency; the declare-form simply suppresses byte-compiler warnings.
(declare-function code-review-minimal--post-comment
                  "code-review-minimal")
(declare-function code-review-minimal--update-comment
                  "code-review-minimal")
(declare-function code-review-minimal--reply-comment
                  "code-review-minimal")

;;;; ─── Buffer-local State ─────────────────────────────────────────────────────

(defvar-local code-review-minimal--overlays nil
  "List of comment overlays created by `code-review-minimal-mode'.")

(defvar-local code-review-minimal--input-overlay nil
  "The currently active comment-input overlay, if any.")

(defvar-local code-review-minimal--input-prompt-end nil
  "Marker pointing to the end of the prompt in the input buffer.")

;;;; ─── Overlay Management ─────────────────────────────────────────────────────

(defun code-review-minimal--clear-overlays ()
  "Remove all comment overlays."
  (mapc #'delete-overlay code-review-minimal--overlays)
  (setq code-review-minimal--overlays nil))

;;;; ─── Overlay Rendering ─────────────────────────────────────────────────────

(defun code-review-minimal--render-note
    (note &optional is-first resolved outdated)
  "Render NOTE alist into propertized string."
  (let* ((author-obj (alist-get 'author note))
         (author
          (if author-obj
              (or (alist-get 'name author-obj)
                  (alist-get 'username author-obj)
                  "unknown")
            "unknown"))
         (created-at (alist-get 'created_at note))
         (body (or (alist-get 'body note) ""))
         (is-resolved (eq resolved t))
         (status-str
          (cond
           ((not is-first)
            "")
           (outdated
            (propertize " ⚠outdated"
                        'face
                        'code-review-minimal-outdated-face))
           (is-resolved
            (propertize " ✓resolved"
                        'face
                        'code-review-minimal-resolved-face))
           ((eq resolved :json-false)
            (propertize " ○open"
                        'face
                        'code-review-minimal-unresolved-face))
           (t
            "")))
         (header
          (concat
           (propertize (format "  💬 %s%s"
                               author
                               (if created-at
                                   (format "  [%s]" created-at)
                                 ""))
                       'face 'code-review-minimal-header-face)
           status-str))
         (body-face
          (if is-resolved
              'code-review-minimal-resolved-body-face
            'code-review-minimal-comment-face))
         (body-lines
          (mapconcat
           (lambda (l) (concat "  │ " l)) (split-string body "\n")
           "\n")))
    (concat
     header "\n" (propertize body-lines 'face body-face) "\n")))

(defun code-review-minimal--insert-discussion-overlay
    (line notes resolved first-note-id &optional outdated)
  "Insert a comment-thread overlay anchored after LINE.
LINE is the 1-based line number in the current buffer at which to anchor
the overlay.  NOTES is the list of note alists belonging to this thread.
RESOLVED is the resolved state of the thread (t, `:json-false', or nil).
FIRST-NOTE-ID is the numeric ID of the thread's root note, stored on the
overlay so that replies and edits can target the correct thread.
OUTDATED is non-nil when the comment's original line no longer exists
in the current diff."
  (unless line
    (cl-return-from code-review-minimal--insert-discussion-overlay))
  (let* ((pos (code-review-minimal--line-end-pos line))
         (ov (make-overlay pos pos nil t nil))
         (first-body (alist-get 'body (car notes)))
         (separator
          (propertize "  ├────────────────\n"
                      'face
                      'code-review-minimal-header-face))
         (text
          (propertize (concat
                       "\n"
                       (mapconcat
                        (lambda (note-and-idx)
                          (code-review-minimal--render-note
                           (car note-and-idx)
                           (= (cdr note-and-idx) 0) resolved outdated))
                        (cl-loop
                         for
                         n
                         in
                         notes
                         for
                         i
                         from
                         0
                         collect
                         (cons n i))
                        separator))
                      'cursor 0)))
    (overlay-put ov 'after-string text)
    (overlay-put ov 'code-review-minimal t)
    (overlay-put ov 'code-review-minimal-note-id first-note-id)
    (overlay-put ov 'code-review-minimal-body first-body)
    (overlay-put ov 'code-review-minimal-resolved resolved)
    (overlay-put ov 'priority 10)
    (push ov code-review-minimal--overlays)))

;;;; ─── Input Overlay ─────────────────────────────────────────────────────────

(defvar code-review-minimal--input-map
  (let ((m (make-sparse-keymap)))
    (define-key
     m (kbd "C-c C-c") #'code-review-minimal--submit-comment)
    (define-key
     m (kbd "C-c C-k") #'code-review-minimal--cancel-comment)
    m)
  "Keymap for comment input.")

(defun code-review-minimal--open-input-overlay
    (beg end &optional edit-note-id initial-body reply-note-id)
  "Open inline input overlay below region BEG..END.
If EDIT-NOTE-ID is non-nil, edit existing note with INITIAL-BODY.
If REPLY-NOTE-ID is non-nil, the submission will post a reply to that thread."
  (when code-review-minimal--input-overlay
    (code-review-minimal--close-input-overlay))
  (let* ((end-pos
          (save-excursion
            (goto-char end)
            (line-end-position)))
         (ov (make-overlay end-pos end-pos nil t nil))
         (ibuf (generate-new-buffer "*code-review-minimal-input*"))
         (editing edit-note-id)
         (replying reply-note-id)
         (prompt
          (propertize (concat
                       (cond
                        (editing
                         "\n  ┌─ Edit CR comment ")
                        (replying
                         "\n  ┌─ Reply to CR comment ")
                        (t
                         "\n  ┌─ New CR comment "))
                       (propertize "(C-c C-c submit, C-c C-k cancel)"
                                   'face
                                   '(:weight normal :slant italic))
                       "\n  │ ")
                      'face
                      'code-review-minimal-input-face
                      'read-only
                      t
                      'rear-nonsticky
                      t)))
    (overlay-put ov 'code-review-minimal-input t)
    (overlay-put ov 'code-review-minimal-region-beg beg)
    (overlay-put ov 'code-review-minimal-region-end end)
    (overlay-put ov 'code-review-minimal-input-buffer ibuf)
    (when editing
      (overlay-put ov 'code-review-minimal-edit-note-id edit-note-id))
    (when replying
      (overlay-put
       ov 'code-review-minimal-reply-note-id reply-note-id))
    (setq code-review-minimal--input-overlay ov)
    (with-current-buffer ibuf
      (code-review-minimal-input-mode)
      (insert prompt)
      (setq-local code-review-minimal--input-overlay ov)
      (setq-local code-review-minimal--input-prompt-end
                  (point-marker))
      (when (and editing initial-body)
        (insert initial-body)))
    (let ((win
           (display-buffer ibuf
                           '(display-buffer-below-selected
                             (window-height . 6)))))
      (when win
        (select-window win)))
    (message
     "Type your comment, then C-c C-c to submit or C-c C-k to cancel.")))

(define-derived-mode
 code-review-minimal-input-mode
 text-mode
 "CR-Input"
 "Transient mode for entering a code review comment."
 (set-buffer-file-coding-system 'utf-8)
 (use-local-map code-review-minimal--input-map)
 (when (fboundp 'evil-emacs-state)
   (evil-emacs-state)))

(defun code-review-minimal--get-input-text ()
  "Extract user text from input buffer."
  (when code-review-minimal--input-overlay
    (let ((ibuf
           (overlay-get
            code-review-minimal--input-overlay
            'code-review-minimal-input-buffer)))
      (when (buffer-live-p ibuf)
        (with-current-buffer ibuf
          (string-trim
           (buffer-substring-no-properties
            code-review-minimal--input-prompt-end (point-max))))))))

(defun code-review-minimal--close-input-overlay ()
  "Close input overlay and clean up."
  (when code-review-minimal--input-overlay
    (let* ((ov code-review-minimal--input-overlay)
           (ibuf (overlay-get ov 'code-review-minimal-input-buffer))
           (src-buf (overlay-buffer ov)))
      (delete-overlay ov)
      (setq code-review-minimal--input-overlay nil)
      (when (and src-buf (buffer-live-p src-buf))
        (with-current-buffer src-buf
          (setq code-review-minimal--input-overlay nil)))
      (when (buffer-live-p ibuf)
        (let ((win (get-buffer-window ibuf)))
          (when win
            (delete-window win)))
        (kill-buffer ibuf)))))

(defun code-review-minimal--cancel-comment ()
  "Cancel comment input."
  (interactive)
  (code-review-minimal--close-input-overlay)
  (message "code-review-minimal: comment cancelled."))

(defun code-review-minimal--submit-comment ()
  "Submit comment to API."
  (interactive)
  (let ((body (code-review-minimal--get-input-text)))
    (if (or (null body) (string-empty-p body))
        (message
         "code-review-minimal: empty comment, not submitting.")
      (let* ((ov code-review-minimal--input-overlay)
             (src-buf (overlay-buffer ov))
             (beg (overlay-get ov 'code-review-minimal-region-beg))
             (end (overlay-get ov 'code-review-minimal-region-end))
             (edit-note-id
              (overlay-get ov 'code-review-minimal-edit-note-id)))
        (with-current-buffer src-buf
          (let ((reply-note-id
                 (overlay-get ov 'code-review-minimal-reply-note-id)))
            (cond
             (edit-note-id
              (code-review-minimal--update-comment edit-note-id body))
             (reply-note-id
              (code-review-minimal--reply-comment reply-note-id body))
             (t
              (code-review-minimal--post-comment beg end body))))
          (deactivate-mark)))))
  (code-review-minimal--close-input-overlay))

;;;; ─── Navigation Helpers ─────────────────────────────────────────────────────

(defun code-review-minimal--overlay-at-point ()
  "Return comment overlay at point."
  (let ((found nil))
    (dolist (ov
             (overlays-in
              (line-beginning-position) (1+ (line-end-position))))
      (when (and (overlay-get ov 'code-review-minimal)
                 (overlay-get ov 'code-review-minimal-note-id))
        (setq found ov)))
    found))

(defun code-review-minimal--sorted-overlay-positions ()
  "Return list of overlay start positions sorted ascending."
  (sort (mapcar #'overlay-start code-review-minimal--overlays) #'<))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-overlay)

;;; code-review-minimal-overlay.el ends here
