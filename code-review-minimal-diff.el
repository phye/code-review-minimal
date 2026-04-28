;;; code-review-minimal-diff.el --- Diff hunk parsing and overlay rendering -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review

;;; Commentary:
;;
;; Unified diff patch parsing and hunk highlight overlay rendering for
;; code-review-minimal.
;;
;; Public API (called from code-review-minimal.el):
;;   `code-review-minimal--clear-hunk-overlays'  — remove all hunk overlays
;;   `code-review-minimal--find-patch-for-file'  — look up patch in change list
;;   `code-review-minimal--insert-hunk-overlays' — parse patch and render overlays
;;
;; Faces are defined in code-review-minimal-custom.el:
;;   `code-review-minimal-hunk-added-face'
;;   `code-review-minimal-hunk-removed-face'
;;   `code-review-minimal-hunk-region-face'

;;; Code:

(require 'cl-lib)
(require 'code-review-minimal-custom)

;; Forward declaration — the authoritative defvar-local is in code-review-minimal.el.
(defvar code-review-minimal--hunk-overlays)

;;;; ─── Hunk Overlay Cleanup ───────────────────────────────────────────────────

(defun code-review-minimal--clear-hunk-overlays ()
  "Remove all hunk highlight overlays."
  (mapc #'delete-overlay code-review-minimal--hunk-overlays)
  (setq code-review-minimal--hunk-overlays nil))

;;;; ─── Diff File Lookup ───────────────────────────────────────────────────────

(defun code-review-minimal--find-patch-for-file (changes rel-path)
  "Find the patch string for REL-PATH in CHANGES list.
Each element of CHANGES is a plist with :old-path, :new-path, and :patch."
  (let ((result
         (cl-loop
          for c in changes when
          (or (string= (plist-get c :new-path) rel-path)
              (string= (plist-get c :old-path) rel-path))
          return (plist-get c :patch))))
    result))

;;;; ─── Diff Parsing ───────────────────────────────────────────────────────────

(defun code-review-minimal--format-removed (lines)
  "Format removed LINES as a display string.
LINES is a list in push-order (most-recent first); the result is
returned in original source order."
  (mapconcat #'identity (nreverse lines) "\n"))

(defun code-review-minimal--truncate-removed-lines (lines)
  "Return LINES truncated to `code-review-minimal-inline-removed-lines-limit'.
When truncated, a footer indicator is appended; pressing `C-c C-d' on it
opens a popup with the full removed block."
  (let ((max-lines code-review-minimal-inline-removed-lines-limit))
    (if (> (length lines) max-lines)
        (append
         (cl-subseq lines 0 max-lines)
         (list
          (propertize
           (format "── … %d more lines … ──"
                   (- (length lines) max-lines))
           'help-echo "Press C-c C-d to view full removed lines")))
      lines)))

(defun code-review-minimal--parse-patch (patch)
  "Parse unified diff PATCH string for a single file.
Return a list of hunk plists:
  (:new-start N :new-count M :added-lines (LINE-NUMS) :removed-segments ((ANCHOR . TEXT) ...))
ANCHOR is the new-file line number after which the removed lines should appear;
0 means before the first line of the hunk."
  (let ((hunks nil)
        (lines (split-string patch "\n")))
    (while lines
      (if (string-match
           "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? [+]\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
           (car lines))
          (let* ((new-start
                  (string-to-number (match-string 3 (car lines))))
                 (new-line new-start)
                 (added-lines nil)
                 (removed-segments nil)
                 (current-removed nil)
                 (last-new-line nil))
            (setq lines (cdr lines))
            (while (and lines
                        (not (string-match "^@@ " (car lines)))
                        (not
                         (string-match "^diff --git" (car lines))))
              (let ((line (car lines)))
                (cond
                 ;; Removed line
                 ((string-prefix-p "-" line)
                  (push (substring line 1) current-removed))
                 ;; Added line
                 ((string-prefix-p "+" line)
                  (when current-removed
                    (push (cons
                           (or last-new-line (1- new-start))
                           (code-review-minimal--format-removed
                            current-removed))
                          removed-segments)
                    (setq current-removed nil))
                  (push new-line added-lines)
                  (setq last-new-line new-line)
                  (cl-incf new-line))
                 ;; Context line or no-newline marker
                 ((or (string-prefix-p " " line)
                      (string-prefix-p "\\" line))
                  (when current-removed
                    (push (cons
                           (or last-new-line (1- new-start))
                           (code-review-minimal--format-removed
                            current-removed))
                          removed-segments)
                    (setq current-removed nil))
                  (setq last-new-line new-line)
                  (cl-incf new-line))
                 ;; Skip anything else (e.g. empty lines in patch)
                 (t
                  nil)))
              (setq lines (cdr lines)))
            ;; Flush remaining removed lines at end of hunk
            (when current-removed
              (push (cons
                     (or last-new-line (1- new-start))
                     (code-review-minimal--format-removed
                      current-removed))
                    removed-segments))
            (push (list
                   :new-start new-start
                   :new-count (- new-line new-start)
                   :added-lines (nreverse added-lines)
                   :removed-segments (nreverse removed-segments))
                  hunks))
        (setq lines (cdr lines))))
    (nreverse hunks)))

;;;; ─── Hunk Overlay Rendering ─────────────────────────────────────────────────

(defun code-review-minimal--insert-hunk-overlays (patch)
  "Parse PATCH and insert hunk highlight overlays into the current buffer."
  (let ((hunks (code-review-minimal--parse-patch patch))
        (buf-lines (line-number-at-pos (point-max))))
    (dolist (hunk hunks)
      (let* ((new-start (plist-get hunk :new-start))
             (new-count (plist-get hunk :new-count))
             (added-lines (plist-get hunk :added-lines))
             (removed-segments (plist-get hunk :removed-segments))
             (end-line (+ new-start new-count -1)))
        ;; Region overlay
        (when (and (>= new-start 1) (<= new-start buf-lines))
          (let* ((beg-pos
                  (save-excursion
                    (goto-char (point-min))
                    (forward-line (1- new-start))
                    (point)))
                 (end-pos
                  (save-excursion
                    (goto-char (point-min))
                    (forward-line (1- (min end-line buf-lines)))
                    (line-end-position)))
                 (ov (make-overlay beg-pos end-pos)))
            (overlay-put
             ov 'face 'code-review-minimal-hunk-region-face)
            (overlay-put ov 'code-review-minimal-hunk t)
            (overlay-put ov 'evaporate t)
            (overlay-put ov 'priority -10)
            (push ov code-review-minimal--hunk-overlays)))
        ;; Added line overlays
        (dolist (line added-lines)
          (when (and (>= line 1) (<= line buf-lines))
            (let* ((beg
                    (save-excursion
                      (goto-char (point-min))
                      (forward-line (1- line))
                      (point)))
                   (end
                    (save-excursion
                      (goto-char (point-min))
                      (forward-line (1- line))
                      (line-end-position)))
                   (ov (make-overlay beg end)))
              (overlay-put
               ov 'before-string
               (propertize " "
                           'display
                           '((margin left-margin) "+")
                           'face
                           'code-review-minimal-hunk-added-face))
              (overlay-put
               ov 'face 'code-review-minimal-hunk-added-face)
              (overlay-put ov 'code-review-minimal-hunk t)
              (overlay-put ov 'evaporate t)
              (overlay-put ov 'priority -10)
              (push ov code-review-minimal--hunk-overlays))))
        ;; Removed line overlays (shown inline via before/after-string)
        (dolist (seg removed-segments)
          (let ((anchor (car seg))
                (text (cdr seg)))
            (cond
             ;; Before first line of buffer
             ((= anchor 0)
              (when (>= buf-lines 1)
                (let* ((pos
                        (save-excursion
                          (goto-char (point-min))
                          (point)))
                       (ov (make-overlay pos pos nil t nil))
                       (lines
                        (code-review-minimal--truncate-removed-lines
                         (split-string text "\n")))
                       (marked-text
                        (mapconcat
                         (lambda (l)
                           (concat
                            (propertize
                             " "
                             'display
                             '((margin left-margin) "-")
                             'face
                             'code-review-minimal-hunk-removed-face)
                            l))
                         lines
                         "\n")))
                  (overlay-put
                   ov 'before-string
                   (propertize
                    (concat marked-text "\n")
                    'face 'code-review-minimal-hunk-removed-face))
                  (overlay-put ov 'code-review-minimal-hunk t)
                  (overlay-put
                   ov 'code-review-minimal-removed-text text)
                  (overlay-put
                   ov 'code-review-minimal-removed-anchor anchor)
                  (overlay-put ov 'priority -10)
                  (push ov code-review-minimal--hunk-overlays))))
             ;; After anchor line
             ((and (>= anchor 1) (<= anchor buf-lines))
              (let* ((pos
                      (save-excursion
                        (goto-char (point-min))
                        (forward-line (1- anchor))
                        (line-end-position)))
                     (ov (make-overlay pos pos nil t nil))
                     (lines
                      (code-review-minimal--truncate-removed-lines
                       (split-string text "\n")))
                     (marked-text
                      (mapconcat
                       (lambda (l)
                         (concat
                          (propertize
                           " "
                           'display
                           '((margin left-margin) "-")
                           'face
                           'code-review-minimal-hunk-removed-face)
                          l))
                       lines
                       "\n")))
                (overlay-put
                 ov 'after-string
                 (propertize
                  (concat "\n" marked-text)
                  'face 'code-review-minimal-hunk-removed-face))
                (overlay-put ov 'code-review-minimal-hunk t)
                (overlay-put
                 ov 'code-review-minimal-removed-text text)
                (overlay-put
                 ov 'code-review-minimal-removed-anchor anchor)
                (overlay-put ov 'priority -10)
                (push ov code-review-minimal--hunk-overlays))))))))))

;;;; ─── View Removed Lines ─────────────────────────────────────────────────────

(defun code-review-minimal--removed-overlay-at-point ()
  "Find the removed-line overlay whose anchor is closest to the current line."
  (let ((best nil)
        (best-dist nil))
    (dolist (ov code-review-minimal--hunk-overlays)
      (when (overlay-get ov 'code-review-minimal-removed-text)
        (let ((anchor
               (overlay-get ov 'code-review-minimal-removed-anchor)))
          (when anchor
            (let ((dist
                   (abs (- (line-number-at-pos (point)) anchor))))
              (when (or (null best-dist) (< dist best-dist))
                (setq best ov)
                (setq best-dist dist)))))))
    best))

(defun code-review-minimal-view-removed-lines ()
  "Pop up a buffer with the full removed lines for the deleted block near point."
  (interactive)
  (let ((ov (code-review-minimal--removed-overlay-at-point)))
    (if (not ov)
        (message "No deleted block near point")
      (let ((full-text
             (overlay-get ov 'code-review-minimal-removed-text))
            (src-mode
             (with-current-buffer (overlay-buffer ov)
               major-mode)))
        (with-current-buffer (get-buffer-create
                              "*code-review-removed-lines*")
          (erase-buffer)
          (insert full-text)
          (funcall src-mode)
          (goto-char (point-min))
          (view-mode))
        (pop-to-buffer "*code-review-removed-lines*")))))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-diff)

;;; code-review-minimal-diff.el ends here
