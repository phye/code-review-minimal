;;; code-review-minimal-custom.el --- Customization variables and faces -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review, faces

;;; Commentary:
;;
;; All `defgroup', `defcustom', and `defface' declarations for
;; code-review-minimal.  Every other file in the package requires this file,
;; so that M-x customize-group shows every option and face in one place.
;;
;; Customization variables:
;;   `code-review-minimal-backend'                    — backend override (nil = auto)
;;   `code-review-minimal-github-api-url'             — GitHub API base URL
;;   `code-review-minimal-gitlab-api-url'             — GitLab API base URL
;;   `code-review-minimal-gongfeng-api-url'           — Gongfeng API base URL
;;   `code-review-minimal-gongfeng-request-timeout'   — per-request timeout (s)
;;   `code-review-minimal-hide-resolved'              — suppress resolved threads
;;   `code-review-minimal-highlight-hunks'            — enable diff hunk overlays
;;   `code-review-minimal-inline-removed-lines-limit' — truncation threshold
;;
;; Faces:
;;   Comment overlays:
;;     `code-review-minimal-comment-face'       — unresolved comment body
;;     `code-review-minimal-resolved-body-face' — resolved comment body
;;     `code-review-minimal-input-face'         — comment-input overlay
;;   Inline status / header:
;;     `code-review-minimal-header-face'        — author/date header line
;;     `code-review-minimal-resolved-face'      — ✓resolved status indicator
;;     `code-review-minimal-unresolved-face'    — ○open status indicator
;;   Hunk highlighting:
;;     `code-review-minimal-hunk-added-face'    — added lines
;;     `code-review-minimal-hunk-removed-face'  — removed lines (inline)
;;     `code-review-minimal-hunk-region-face'   — overall hunk region background
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
;;
;; Light theme — soft tinted backgrounds, dark foregrounds for legibility:
;;   • comment bg  #edf4ff  (light blue tint) fg  #1a3a6e  (dark navy)
;;   • resolved bg #edfaed  (light green)     fg  #1a4a1a  (dark green)
;;   • input bg    #f0fff0  (mint)             fg  #1a4a1a  (dark green)
;;   • header fg   #1a4080  (dark blue)
;;   • resolved fg #1a6a1a  (dark green)
;;   • open fg     #1a4080  (dark blue)

;;; Code:

;;;; ─── Group ──────────────────────────────────────────────────────────────────

(defgroup code-review-minimal nil
  "Code-review overlays for GitHub/GitLab/Gongfeng Pull/Merge Requests."
  :group 'tools
  :prefix "code-review-minimal-")

;;;; ─── Backend ────────────────────────────────────────────────────────────────

(defcustom code-review-minimal-backend nil
  "Backend override for code review.
If nil (the default), the backend is auto-detected from the git remote URL
and the result is cached per repository.  Only set this when auto-detection
fails or gives the wrong result for a particular repository.

Valid values: nil (auto), or any backend symbol registered in
`code-review-minimal-backend-registry' (e.g. `github', `gitlab', `gongfeng').

This variable is intended to be set per-repository via a .dir-locals.el file:

  ((nil . ((code-review-minimal-backend . gongfeng))))

It is declared safe for directory-local use so Emacs will not prompt for
confirmation when the value is a registered backend symbol."
  :type
  '(choice
    (const :tag "Auto-detect" nil)
    (const :tag "GitHub" github)
    (const :tag "GitLab" gitlab)
    (const :tag "Gongfeng (工蜂)" gongfeng))
  :group 'code-review-minimal)

;; Derived from the registry at runtime so new backends are automatically valid.
;; `code-review-minimal-backend-registry' is defined in code-review-minimal-backend.el,
;; which loads after this file; the lambda is only called at dir-local validation
;; time (not at load time), so the forward reference is safe.
(put
 'code-review-minimal-backend 'safe-local-variable
 (lambda (v)
   (or (null v)
       (and (boundp 'code-review-minimal-backend-registry)
            (assq v code-review-minimal-backend-registry)))))

;;;; ─── API URLs ───────────────────────────────────────────────────────────────

(defcustom code-review-minimal-github-api-url "https://api.github.com"
  "Base URL for GitHub API.
For GitHub Enterprise, use: https://your-github-enterprise.com/api/v3"
  :type 'string
  :group 'code-review-minimal)

(defcustom code-review-minimal-gitlab-api-url
  "https://gitlab.com/api/v4"
  "Base URL for GitLab API.
For self-hosted GitLab, use: https://your-gitlab.com/api/v4"
  :type 'string
  :group 'code-review-minimal)

(defcustom code-review-minimal-gongfeng-api-url
  "https://git.woa.com/api/v3"
  "Base URL for Gongfeng API."
  :type 'string
  :group 'code-review-minimal)

;;;; ─── Gongfeng HTTP ──────────────────────────────────────────────────────────

(defcustom code-review-minimal-gongfeng-request-timeout 30
  "Timeout in seconds for Gongfeng HTTP requests.
If a request does not complete within this many seconds it is aborted
and an error is logged to the *Messages* buffer."
  :type 'integer
  :group 'code-review-minimal)

;;;; ─── Display ────────────────────────────────────────────────────────────────

(defcustom code-review-minimal-hide-resolved nil
  "When non-nil, do not render overlays for resolved comment threads."
  :type 'boolean
  :group 'code-review-minimal)

(defcustom code-review-minimal-highlight-hunks t
  "When non-nil, highlight diff hunks with overlays in review buffers.
Added lines are shown with a green tint, removed lines are displayed
inline in red, and the overall hunk region gets a subtle background."
  :type 'boolean
  :group 'code-review-minimal)

(defcustom code-review-minimal-inline-removed-lines-limit 5
  "Maximum number of removed lines to display inline.
When a deleted block exceeds this count, the remaining lines are hidden
behind a truncation indicator; use `code-review-minimal-view-removed-lines'
to view the full block in a popup buffer."
  :type 'integer
  :group 'code-review-minimal)

;;;; ─── Comment overlay faces ─────────────────────────────────────────────────

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

;;;; ─── Inline status / header faces ─────────────────────────────────────────

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

;;;; ─── Hunk highlighting faces ───────────────────────────────────────────────

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

(provide 'code-review-minimal-custom)

;;; code-review-minimal-custom.el ends here
