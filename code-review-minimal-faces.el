;;; code-review-minimal-faces.el --- Faces for code-review-minimal -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review, faces

;;; Commentary:
;;
;; Face definitions for code-review-minimal.
;;
;; Each face defines two variants via Emacs's built-in face spec mechanism:
;;   ((background dark)  ...) — for dark themes
;;   (t                  ...) — for light themes (catch-all)
;;
;; Color palette
;; ─────────────
;; Dark theme — muted blues/greens on dark backgrounds, high enough contrast
;;   for readability without being jarring next to source code:
;;   • comment bg  #1e2a3a  (deep navy)    fg  #9ec8f0  (sky blue)
;;   • resolved bg #1a2e1a  (deep green)   fg  #7ec87e  (sage green)
;;   • input bg    #1e2e1e  (deep green)   fg  #98e898  (light green)
;;   • header fg   #6ab0e8  (cornflower)
;;   • resolved fg #5ec45e  (medium green)
;;   • open fg     #6ab0e8  (cornflower)
;;   • box colors are a lighter shade of the bg for a subtle inset border
;;
;; Light theme — soft tinted backgrounds, dark foregrounds for legibility:
;;   • comment bg  #edf4ff  (light blue tint) fg  #1a3a6e  (dark navy)
;;   • resolved bg #edfaed  (light green)     fg  #1a4a1a  (dark green)
;;   • input bg    #f0fff0  (mint)             fg  #1a4a1a  (dark green)
;;   • header fg   #1a4080  (dark blue)
;;   • resolved fg #1a6a1a  (dark green)
;;   • open fg     #1a4080  (dark blue)
;;   • box colors are a mid-shade of the same hue for a clear border

;;; Code:

;;;; ─── Comment overlay ────────────────────────────────────────────────────────

(defface code-review-minimal-comment-face
  '((((background dark))
     :background "#1e2a3a"
     :foreground "#9ec8f0"
     :box (:line-width 1 :color "#3a5a7a")
     :extend t)
    (t
     :background "#edf4ff"
     :foreground "#1a3a6e"
     :box (:line-width 1 :color "#7aaad8")
     :extend t))
  "Face for the body of an unresolved CR comment overlay."
  :group 'code-review-minimal)

(defface code-review-minimal-resolved-body-face
  '((((background dark))
     :background "#1a2e1a"
     :foreground "#7ec87e"
     :box (:line-width 1 :color "#2e5e2e")
     :extend t)
    (t
     :background "#edfaed"
     :foreground "#1a4a1a"
     :box (:line-width 1 :color "#6ab86a")
     :extend t))
  "Face for the body of a resolved CR comment overlay."
  :group 'code-review-minimal)

(defface code-review-minimal-input-face
  '((((background dark))
     :background "#1e2e1e"
     :foreground "#98e898"
     :box (:line-width 1 :color "#366836")
     :extend t)
    (t
     :background "#f0fff0"
     :foreground "#1a4a1a"
     :box (:line-width 1 :color "#6ab86a")
     :extend t))
  "Face for the comment-input overlay."
  :group 'code-review-minimal)

;;;; ─── Inline status / header ─────────────────────────────────────────────────

(defface code-review-minimal-header-face
  '((((background dark)) :foreground "#6ab0e8" :weight bold)
    (t :foreground "#1a4080" :weight bold))
  "Face for the header line (author, date) inside a comment overlay."
  :group 'code-review-minimal)

(defface code-review-minimal-resolved-face
  '((((background dark)) :foreground "#5ec45e" :weight bold)
    (t :foreground "#1a6a1a" :weight bold))
  "Face for the ✓resolved status indicator in a comment overlay."
  :group 'code-review-minimal)

(defface code-review-minimal-unresolved-face
  '((((background dark)) :foreground "#6ab0e8" :weight bold)
    (t :foreground "#1a4080" :weight bold))
  "Face for the ○open status indicator in a comment overlay."
  :group 'code-review-minimal)

;;;; ─── Hunk highlighting ─────────────────────────────────────────────────────

(defface code-review-minimal-hunk-added-face
  '((((background dark))
     :background "#1a3a1a"
     :foreground "#7ec87e"
     :extend t)
    (t :background "#edfaed" :foreground "#1a4a1a" :extend t))
  "Face for lines added in the current MR/PR diff."
  :group 'code-review-minimal)

(defface code-review-minimal-hunk-removed-face
  '((((background dark))
     :background "#8b1a1a"
     :foreground "#ffc0c0"
     :extend t)
    (t :background "#ffcccc" :foreground "#4a0000" :extend t))
  "Face for removed lines shown inline in the diff overlay."
  :group 'code-review-minimal)

(defface code-review-minimal-hunk-region-face
  '((((background dark)) :background "#1e2530" :extend t)
    (t :background "#f0f4f8" :extend t))
  "Face for the overall hunk region background."
  :group 'code-review-minimal)

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-faces)

;;; code-review-minimal-faces.el ends here
