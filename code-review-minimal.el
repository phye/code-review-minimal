;;; code-review-minimal.el --- Minimal Code Review with overlay for GitHub/GitLab/Gongfeng -*- lexical-binding: t; -*-

;; Author: phye
;; Version: 0.2.0
;; Keywords: tools, vc, review
;; Package-Requires: ((emacs "27.1") (ghub "3.6"))

;;; Commentary:
;;
;; code-review-minimal is a lightweight minor mode for performing code review
;; directly inside Emacs against GitHub Pull Requests, GitLab Merge Requests,
;; and Gongfeng (Tencent GitLab) MRs.
;;
;; Quick start:
;;   1. Add an entry to ~/.authinfo (or ~/.authinfo.gpg) for each forge you use:
;;        machine api.github.com  login ^crm password <github-token>
;;        machine gitlab.com      login ^crm password <gitlab-token>
;;        machine git.woa.com      login ^crm password <gongfeng-token>
;;        machine code.tencent.com login ^crm password <gongfeng-token>
;;      The `^crm' login distinguishes these entries from tokens used by other
;;      Emacs forge tools (e.g. Magit/ghub use `^').
;;      The host is taken from `code-review-minimal-*-base-url', so GitHub
;;      Enterprise and self-hosted GitLab instances work automatically by
;;      setting the appropriate base-URL custom variable.
;;
;;   2. Start a review session from a PR/MR web URL:
;;        M-x code-review-minimal-review-url
;;      The backend (github/gitlab/gongfeng) is auto-detected from the URL host
;;      and the git remote.  Inline comment overlays are rendered immediately.
;;
;;   3. To post a new comment, select a region and run:
;;        M-x code-review-minimal-add-comment
;;      An overlay input area opens beneath the selection.
;;      Type your comment and press C-c C-c to submit, or C-c C-k to cancel.
;;
;; Supported backends:
;;   - github    : github.com and GitHub Enterprise
;;                 HTTP: ghub (Authorization: Bearer <token>)
;;   - gitlab    : gitlab.com and self-hosted GitLab (API v4)
;;                 HTTP: ghub with :forge 'gitlab (PRIVATE-TOKEN header)
;;   - gongfeng  : git.woa.com / code.tencent.com — Tencent's Gongfeng (工蜂) (API v3)
;;                 HTTP: url-retrieve with explicit PRIVATE-TOKEN header
;;                 (Gongfeng's API v3 is not wire-compatible with GitLab v4)
;;
;; Backend files:
;;   code-review-minimal-github.el   — GitHub backend
;;   code-review-minimal-gitlab.el   — GitLab backend
;;   code-review-minimal-gongfeng.el — Gongfeng backend
;;   code-review-minimal-faces.el    — Face definitions (light + dark themes)
;;
;; License: MIT

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'auth-source)
(require 'code-review-minimal-faces)
(require 'code-review-minimal-github)
(require 'code-review-minimal-gitlab)
(require 'code-review-minimal-gongfeng)

;;;; ─── Customisation ────────────────────────────────────────────────────────

(defgroup code-review-minimal nil
  "Code-review overlays for GitHub/GitLab/Gongfeng Pull/Merge Requests."
  :group 'tools
  :prefix "code-review-minimal-")

(defcustom code-review-minimal-backend nil
  "Backend override for code review.
If nil (the default), the backend is auto-detected from the git remote URL
and the result is cached per repository.  Only set this when auto-detection
fails or gives the wrong result for a particular repository.

Valid values: nil (auto), `github', `gitlab', `gongfeng'.

This variable is intended to be set per-repository via a .dir-locals.el file:

  ((nil . ((code-review-minimal-backend . gongfeng))))

It is declared safe for directory-local use so Emacs will not prompt for
confirmation when the value is one of the known backend symbols."
  :type '(choice (const :tag "Auto-detect" nil)
                 (const :tag "GitHub" github)
                 (const :tag "GitLab" gitlab)
                 (const :tag "Gongfeng (Tencent GitLab)" gongfeng))
  :group 'code-review-minimal)

(put 'code-review-minimal-backend 'safe-local-variable
     (lambda (v) (memq v '(nil github gitlab gongfeng))))

;; API base URLs
(defcustom code-review-minimal-github-base-url "https://api.github.com"
  "Base URL for GitHub API.
For GitHub Enterprise, use: https://your-github-enterprise.com/api/v3"
  :type 'string
  :group 'code-review-minimal)

(defcustom code-review-minimal-gitlab-base-url "https://gitlab.com/api/v4"
  "Base URL for GitLab API.
For self-hosted GitLab, use: https://your-gitlab.com/api/v4"
  :type 'string
  :group 'code-review-minimal)

(defcustom code-review-minimal-gongfeng-base-url "https://git.woa.com/api/v3"
  "Base URL for Gongfeng API."
  :type 'string
  :group 'code-review-minimal)

;;;; ─── Backend Detection ─────────────────────────────────────────────────────

(defun code-review-minimal--detect-backend (remote-url)
  "Auto-detect backend from REMOTE-URL.
Returns one of: github, gitlab, gongfeng, or nil."
  (cond
   ;; Gongfeng (工蜂) — git.woa.com (internal) or code.tencent.com (external)
   ((string-match-p "git\\.woa\\.com\\|code\\.tencent\\.com" remote-url)
    'gongfeng)
   ;; GitHub
   ((or (string-match-p "github\.com" remote-url)
        (string-match-p "github" remote-url))
    'github)
   ;; Generic GitLab
   ((string-match-p "gitlab" remote-url)
    'gitlab)
   ;; Default to nil if unknown
   (t nil)))

;;;; ─── Per-repo Cache ─────────────────────────────────────────────────────────

(defvar code-review-minimal--iid-cache (make-hash-table :test 'equal)
  "In-memory cache mapping git-root (string) → MR IID (integer).")

(defvar code-review-minimal--backend-cache (make-hash-table :test 'equal)
  "In-memory cache mapping git-root (string) → backend symbol.")

(defun code-review-minimal--git-root ()
  "Return the absolute path to the git root for the current buffer, or nil."
  (when-let ((root (locate-dominating-file (or buffer-file-name default-directory) ".git")))
    (expand-file-name root)))

(defun code-review-minimal--cache-file (filename)
  "Return the path to a per-repo cache file in .git/ directory."
  (when-let ((root (code-review-minimal--git-root)))
    (expand-file-name filename (expand-file-name ".git" root))))

(defun code-review-minimal--load-cached-iid ()
  "Return the persisted MR IID for the current repo, or nil."
  (let ((root (code-review-minimal--git-root)))
    (or (and root (gethash root code-review-minimal--iid-cache))
        (when-let ((file (code-review-minimal--cache-file "code-review-minimal-iid")))
          (when (file-readable-p file)
            (let* ((raw (with-temp-buffer
                          (insert-file-contents file)
                          (string-trim (buffer-string))))
                   (iid (string-to-number raw)))
              (when (and (integerp iid) (> iid 0))
                (when root
                  (puthash root iid code-review-minimal--iid-cache))
                iid)))))))

(defun code-review-minimal--save-iid (iid)
  "Persist IID for the current repo."
  (when-let ((root (code-review-minimal--git-root)))
    (puthash root iid code-review-minimal--iid-cache))
  (when-let ((file (code-review-minimal--cache-file "code-review-minimal-iid")))
    (write-region (number-to-string iid) nil file nil 'silent)))

(defun code-review-minimal--load-cached-backend ()
  "Return the persisted backend for the current repo, or nil."
  (let ((root (code-review-minimal--git-root)))
    (or (and root (gethash root code-review-minimal--backend-cache))
        (when-let ((file (code-review-minimal--cache-file "code-review-minimal-backend")))
          (when (file-readable-p file)
            (let ((backend (with-temp-buffer
                             (insert-file-contents file)
                             (string-trim (buffer-string)))))
              (when (> (length backend) 0)
                (when root
                  (puthash root backend code-review-minimal--backend-cache))
                (intern backend))))))))

(defun code-review-minimal--save-backend (backend)
  "Persist BACKEND for the current repo."
  (when-let ((root (code-review-minimal--git-root)))
    (puthash root backend code-review-minimal--backend-cache))
  (when-let ((file (code-review-minimal--cache-file "code-review-minimal-backend")))
    (write-region (symbol-name backend) nil file nil 'silent)))

;;;; ─── Buffer-local State ────────────────────────────────────────────────────

(defvar-local code-review-minimal--mr-iid nil
  "MR IID (per-project integer id) currently being reviewed.")

(defvar-local code-review-minimal--mr-id nil
  "MR global integer id resolved from `code-review-minimal--mr-iid'.")

(defvar-local code-review-minimal--project-info nil
  "Project info alist with backend-specific keys.
GitHub: ((owner . \"user\") (repo . \"project\"))
GitLab/Gongfeng: ((project-id . \"namespace%2Fproject\"))")

(defvar-local code-review-minimal--current-backend nil
  "The backend symbol currently in use (github, gitlab, gongfeng).")

(defvar-local code-review-minimal--overlays nil
  "List of comment overlays created by `code-review-minimal-mode'.")

(defvar-local code-review-minimal--input-overlay nil
  "The currently active comment-input overlay, if any.")

(defvar-local code-review-minimal--input-prompt-end nil
  "Marker pointing to the end of the prompt in the input buffer.")

;;;; ─── Token Management ──────────────────────────────────────────────────────

(defun code-review-minimal--git-config (key)
  "Return the value of git config KEY, or nil if unset."
  (let ((val (string-trim
              (shell-command-to-string
               (format "git config --global %s 2>/dev/null" key)))))
    (and (not (string-empty-p val)) val)))

(defun code-review-minimal--authinfo-token (host backend)
  "Look up a token for HOST in authinfo/netrc via `auth-source'.
Returns the secret string, or nil if not found.

Searches in order:
  1. login ^crm                   — dedicated code-review-minimal entry
  2. login <git-config-user>^crm  — per-user entry (git config BACKEND.user)
  3. any login on HOST            — fallback"
  (let* ((git-user (code-review-minimal--git-config
                    (format "%s.user" (symbol-name backend))))
         (found
          (or (car (auth-source-search :host host :user "^crm" :max 1))
              (and git-user
                   (car (auth-source-search :host host
                                            :user (concat git-user "^crm")
                                            :max 1)))
              (car (auth-source-search :host host :max 1)))))
    (when found
      (let ((secret (plist-get found :secret)))
        (if (functionp secret) (funcall secret) secret)))))

(defun code-review-minimal--get-token (backend)
  "Get the authentication token for BACKEND from authinfo/netrc.
The host is derived from the backend's API base-URL custom variable,
so GitHub Enterprise and self-hosted GitLab instances are supported
automatically."
  (code-review-minimal--authinfo-token
   (replace-regexp-in-string
    "^https?://\\([^/]+\\).*" "\\1"
    (pcase backend
      ('github   code-review-minimal-github-base-url)
      ('gitlab   code-review-minimal-gitlab-base-url)
      ('gongfeng code-review-minimal-gongfeng-base-url)
      (_ (error "Unknown backend: %s" backend))))
   backend))

(defun code-review-minimal--assert-token (backend)
  "Signal an error if no token is found in authinfo for BACKEND."
  (unless (let ((tok (code-review-minimal--get-token backend)))
            (and (stringp tok) (not (string-empty-p tok))))
    (user-error
     "code-review-minimal: No token found for %s.  \
Add an entry to ~/.authinfo (or ~/.authinfo.gpg), e.g.:\n  machine %s login ^crm password <token>"
     backend
     (replace-regexp-in-string
      "^https?://\\([^/]+\\).*" "\\1"
      (pcase backend
        ('github   code-review-minimal-github-base-url)
        ('gitlab   code-review-minimal-gitlab-base-url)
        ('gongfeng code-review-minimal-gongfeng-base-url)
        (_ "unknown-host"))))))

;;;; ─── Remote Parsing ────────────────────────────────────────────────────────

(defun code-review-minimal--git-remote-url ()
  "Return the URL of the `origin' remote."
  (let ((default-directory
         (or (locate-dominating-file (or buffer-file-name default-directory) ".git")
             default-directory)))
    (string-trim (shell-command-to-string "git remote get-url origin 2>/dev/null"))))

(defun code-review-minimal--parse-mr-url (input)
  "Parse a MR/PR URL or bare integer INPUT.
Returns a plist with :iid and optionally :backend and :project-info, or nil.

Supported URL formats:
  GitHub:   https://github.com/OWNER/REPO/pull/IID
  GitLab:   https://gitlab.com/NS/PROJECT/-/merge_requests/IID
  Gongfeng: https://git.woa.com/NS/PROJECT/-/merge_requests/IID"
  (when (and input (not (string-empty-p (string-trim input))))
    (let ((s (string-trim input)))
      (cond
       ;; GitHub: https://HOST/OWNER/REPO/pull[s]/IID
       ((string-match
         "https?://\\([^/]*github[^/]*\\)/\\([^/]+\\)/\\([^/]+\\)/pulls?/\\([0-9]+\\)" s)
        (list :iid          (string-to-number (match-string 4 s))
              :backend      'github
              :project-info `((owner . ,(match-string 2 s))
                              (repo  . ,(match-string 3 s)))))
       ;; GitLab / Gongfeng: https://HOST/NS/.../REPO/-/merge_requests/IID
       ((string-match
         "https?://\\([^/]+\\)/\\(.*\\)/-/merge_requests/\\([0-9]+\\)" s)
        (let* ((host    (match-string 1 s))
               (path    (match-string 2 s))
               (iid     (string-to-number (match-string 3 s)))
               (backend (code-review-minimal--detect-backend host)))
          (list :iid          iid
                :backend      backend   ; nil when host is unknown; --ensure-backend will handle it
                :project-info `((project-id . ,(url-hexify-string path))))))
       ;; Bare integer fallback
       ((string-match "\\`[0-9]+\\'" s)
        (list :iid (string-to-number s)))))))

;;;; ─── Backend Selection ─────────────────────────────────────────────────────

(defun code-review-minimal--ensure-backend ()
  "Determine and return the backend to use.
Uses `code-review-minimal-backend' if set, otherwise auto-detects from remote URL.
Caches the result per repository."
  (unless code-review-minimal--current-backend
    (let ((cached (code-review-minimal--load-cached-backend)))
      (if cached
          (setq code-review-minimal--current-backend cached)
        ;; Auto-detect or use configured default
        (let* ((remote (code-review-minimal--git-remote-url))
               (detected (code-review-minimal--detect-backend remote))
               (backend (or code-review-minimal-backend detected)))
          (if backend
              (progn
                (setq code-review-minimal--current-backend backend)
                (code-review-minimal--save-backend backend)
                (message "code-review-minimal: auto-detected %s backend from remote" backend))
            (user-error "code-review-minimal: Cannot detect backend from remote: %s. Please set `code-review-minimal-backend'" remote))))))
  code-review-minimal--current-backend)

;;;; ─── Utility Functions ─────────────────────────────────────────────────────

(defun code-review-minimal--relative-file-path ()
  "Return the path of the current buffer's file relative to git root."
  (when buffer-file-name
    (let* ((root (locate-dominating-file buffer-file-name ".git")))
      (if root
          (file-relative-name buffer-file-name (expand-file-name root))
        (file-name-nondirectory buffer-file-name)))))

(defun code-review-minimal--line-number-at (pos)
  "Return 1-based line number for POS."
  (save-excursion
    (goto-char pos)
    (line-number-at-pos)))

(defun code-review-minimal--line-end-pos (line)
  "Return buffer position at end of LINE (1-based)."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (line-end-position)))

(defun code-review-minimal--clear-overlays ()
  "Remove all comment overlays."
  (mapc #'delete-overlay code-review-minimal--overlays)
  (setq code-review-minimal--overlays nil))

;;;; ─── Overlay Rendering ─────────────────────────────────────────────────────

(defun code-review-minimal--render-note (note &optional is-first resolved)
  "Render NOTE alist into propertized string."
  (let* ((author-obj (alist-get 'author note))
         (author (if author-obj
                     (or (alist-get 'name author-obj)
                         (alist-get 'username author-obj)
                         "unknown")
                   "unknown"))
         (created-at (alist-get 'created_at note))
         (body (or (alist-get 'body note) ""))
         (is-resolved (eq resolved t))
         (status-str
          (cond
           ((not is-first) "")
           (is-resolved (propertize " ✓resolved" 'face 'code-review-minimal-resolved-face))
           ((eq resolved :json-false) (propertize " ○open" 'face 'code-review-minimal-unresolved-face))
           (t "")))
         (header (concat
                  (propertize (format "  💬 %s%s"
                                      author
                                      (if created-at
                                          (format "  [%s]" created-at)
                                        ""))
                              'face 'code-review-minimal-header-face)
                  status-str))
         (body-face (if is-resolved
                        'code-review-minimal-resolved-body-face
                      'code-review-minimal-comment-face))
         (body-lines (mapconcat (lambda (l) (concat "  │ " l))
                                (split-string body "\n") "\n")))
    (concat header "\n" (propertize body-lines 'face body-face) "\n")))

(defun code-review-minimal--insert-discussion-overlay (line notes resolved first-note-id)
  "Insert overlay after LINE with NOTES thread."
  (let* ((pos (code-review-minimal--line-end-pos line))
         (ov (make-overlay pos pos nil t nil))
         (first-body (alist-get 'body (car notes)))
         (separator (propertize "  ├────────────────\n" 'face 'code-review-minimal-header-face))
         (text (propertize
                (concat "\n"
                        (mapconcat
                         (lambda (note-and-idx)
                           (code-review-minimal--render-note (car note-and-idx)
                                                     (= (cdr note-and-idx) 0)
                                                     resolved))
                         (cl-loop for n in notes for i from 0 collect (cons n i))
                         separator))
                'cursor 0)))
    (overlay-put ov 'after-string text)
    (overlay-put ov 'code-review-minimal t)
    (overlay-put ov 'code-review-minimal-note-id first-note-id)
    (overlay-put ov 'code-review-minimal-body first-body)
    (overlay-put ov 'code-review-minimal-resolved resolved)
    (push ov code-review-minimal--overlays)))

;;;; ─── Input Overlay ─────────────────────────────────────────────────────────

(defvar code-review-minimal--input-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'code-review-minimal--submit-comment)
    (define-key m (kbd "C-c C-k") #'code-review-minimal--cancel-comment)
    m)
  "Keymap for comment input.")

(defun code-review-minimal--open-input-overlay (beg end &optional edit-note-id initial-body)
  "Open inline input overlay below region BEG..END.
If EDIT-NOTE-ID is non-nil, edit existing note with INITIAL-BODY."
  (when code-review-minimal--input-overlay
    (code-review-minimal--close-input-overlay))
  (let* ((end-pos (save-excursion
                    (goto-char end)
                    (line-end-position)))
         (ov (make-overlay end-pos end-pos nil t nil))
         (ibuf (generate-new-buffer "*code-review-minimal-input*"))
         (editing edit-note-id)
         (prompt (propertize
                  (concat (if editing "\n  ┌─ Edit CR comment " "\n  ┌─ New CR comment ")
                          (propertize "(C-c C-c submit, C-c C-k cancel)"
                                      'face '(:weight normal :slant italic))
                          "\n  │ ")
                  'face 'code-review-minimal-input-face
                  'read-only t
                  'rear-nonsticky t)))
    (overlay-put ov 'code-review-minimal-input t)
    (overlay-put ov 'code-review-minimal-region-beg beg)
    (overlay-put ov 'code-review-minimal-region-end end)
    (overlay-put ov 'code-review-minimal-input-buffer ibuf)
    (when editing
      (overlay-put ov 'code-review-minimal-edit-note-id edit-note-id))
    (setq code-review-minimal--input-overlay ov)
    (with-current-buffer ibuf
      (code-review-minimal-input-mode)
      (insert prompt)
      (setq-local code-review-minimal--input-overlay ov)
      (setq-local code-review-minimal--input-prompt-end (point-marker))
      (when (and editing initial-body)
        (insert initial-body)))
    (let ((win (display-buffer ibuf '(display-buffer-below-selected (window-height . 6)))))
      (when win
        (select-window win)))
    (message "Type your comment, then C-c C-c to submit or C-c C-k to cancel.")))

(define-derived-mode code-review-minimal-input-mode text-mode "CR-Input"
  "Transient mode for entering a code review comment."
  (set-buffer-file-coding-system 'utf-8)
  (use-local-map code-review-minimal--input-map)
  (when (fboundp 'evil-emacs-state)
    (evil-emacs-state)))

(defun code-review-minimal--get-input-text ()
  "Extract user text from input buffer."
  (when code-review-minimal--input-overlay
    (let ((ibuf (overlay-get code-review-minimal--input-overlay 'code-review-minimal-input-buffer)))
      (when (buffer-live-p ibuf)
        (with-current-buffer ibuf
          (string-trim
           (buffer-substring-no-properties code-review-minimal--input-prompt-end (point-max))))))))

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
        (message "code-review-minimal: empty comment, not submitting.")
      (let* ((ov code-review-minimal--input-overlay)
             (src-buf (overlay-buffer ov))
             (beg (overlay-get ov 'code-review-minimal-region-beg))
             (end (overlay-get ov 'code-review-minimal-region-end))
             (edit-note-id (overlay-get ov 'code-review-minimal-edit-note-id)))
        (with-current-buffer src-buf
          (if edit-note-id
              (code-review-minimal--update-comment edit-note-id body)
            (code-review-minimal--post-comment beg end body))
          (deactivate-mark)))))
  (code-review-minimal--close-input-overlay))

;;;; ─── Backend Dispatch Functions ────────────────────────────────────────────

(defun code-review-minimal--fetch-comments ()
  "Fetch comments using current backend."
  (pcase code-review-minimal--current-backend
    ('github   (code-review-minimal--github-fetch-comments))
    ('gitlab   (code-review-minimal--gitlab-fetch-comments))
    ('gongfeng (code-review-minimal--gongfeng-fetch-comments))
    (_ (error "Unknown backend: %s" code-review-minimal--current-backend))))

(defun code-review-minimal--post-comment (beg end body)
  "Post comment using current backend."
  (pcase code-review-minimal--current-backend
    ('github   (code-review-minimal--github-post-comment beg end body))
    ('gitlab   (code-review-minimal--gitlab-post-comment beg end body))
    ('gongfeng (code-review-minimal--gongfeng-post-comment beg end body))
    (_ (error "Unknown backend: %s" code-review-minimal--current-backend))))

(defun code-review-minimal--update-comment (note-id body)
  "Update comment using current backend."
  (pcase code-review-minimal--current-backend
    ('github   (code-review-minimal--github-update-comment note-id body))
    ('gitlab   (code-review-minimal--gitlab-update-comment note-id body))
    ('gongfeng (code-review-minimal--gongfeng-update-comment note-id body))
    (_ (error "Unknown backend: %s" code-review-minimal--current-backend))))

(defun code-review-minimal--resolve-comment (ov)
  "Resolve comment using current backend."
  (pcase code-review-minimal--current-backend
    ('github   (code-review-minimal--github-resolve-comment ov))
    ('gitlab   (code-review-minimal--gitlab-resolve-comment ov))
    ('gongfeng (code-review-minimal--gongfeng-resolve-comment ov))
    (_ (error "Unknown backend: %s" code-review-minimal--current-backend))))

;;;; ─── Public Commands ───────────────────────────────────────────────────────

(defun code-review-minimal--overlay-at-point ()
  "Return comment overlay at point."
  (let ((found nil))
    (dolist (ov (overlays-in (line-beginning-position) (1+ (line-end-position))))
      (when (and (overlay-get ov 'code-review-minimal)
                 (overlay-get ov 'code-review-minimal-note-id))
        (setq found ov)))
    found))

;;;###autoload
(defun code-review-minimal-review-url (url)
  "Start a code review session for the MR/PR at URL.
URL must be a full web URL of a pull/merge request, e.g.:
  https://git.woa.com/adp/proto-unified/-/merge_requests/856
  https://github.com/owner/repo/pull/42
  https://gitlab.com/ns/project/-/merge_requests/7

Automatically detects the backend (github/gitlab/gongfeng), project, and
MR IID from the URL, then enables `code-review-minimal-mode' and fetches
inline comments for the current buffer."
  (interactive (list (read-string "MR/PR URL: ")))
  (let ((parsed (code-review-minimal--parse-mr-url url)))
    (unless (and parsed (plist-get parsed :iid))
      (user-error "code-review-minimal: expected a full MR/PR URL, got: %S" url))
    (let ((iid      (plist-get parsed :iid))
          (backend  (plist-get parsed :backend))
          (projinfo (plist-get parsed :project-info)))
      ;; Install state before enabling the mode so mode-activation sees it.
      ;; backend may be nil for unrecognised hosts; --ensure-backend will
      ;; auto-detect from the git remote in that case.
      (setq code-review-minimal--mr-iid          iid
            code-review-minimal--mr-id           nil
            code-review-minimal--project-info    projinfo)
      (when backend
        (setq code-review-minimal--current-backend backend)
        (code-review-minimal--save-backend backend))
      (code-review-minimal--save-iid iid)
      (code-review-minimal--ensure-backend)
      (code-review-minimal--assert-token code-review-minimal--current-backend)
      (message "code-review-minimal: reviewing !%d on %s [%s]" iid
               (or (alist-get 'project-id projinfo)
                   (format "%s/%s" (alist-get 'owner projinfo) (alist-get 'repo projinfo)))
               code-review-minimal--current-backend)
      ;; Enable mode (which fetches comments) or just refresh if already on
      (if (bound-and-true-p code-review-minimal-mode)
          (code-review-minimal--fetch-comments)
        (code-review-minimal-mode 1)))))

;;;###autoload
(defun code-review-minimal-set-backend-for-repo (backend)
  "Set and persist the backend for the current repository.
Use this to override auto-detection."
  (interactive (list (intern (completing-read "Backend: " '("github" "gitlab" "gongfeng")))))
  (setq code-review-minimal--current-backend backend)
  (code-review-minimal--save-backend backend)
  (message "code-review-minimal: backend set to %s (persisted)." backend))

;;;###autoload
(defun code-review-minimal-add-comment (beg end)
  "Add a code review comment for selected region BEG..END."
  (interactive "r")
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (unless code-review-minimal--mr-iid
    (user-error "code-review-minimal: no MR IID set"))
  (code-review-minimal--assert-token code-review-minimal--current-backend)
  (code-review-minimal--open-input-overlay beg end))

;;;###autoload
(defun code-review-minimal-edit-comment ()
  "Edit the code review comment at point."
  (interactive)
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (let ((ov (code-review-minimal--overlay-at-point)))
    (unless ov
      (user-error "code-review-minimal: no comment overlay on this line"))
    (let ((note-id (overlay-get ov 'code-review-minimal-note-id))
          (note-body (overlay-get ov 'code-review-minimal-body))
          (line (line-beginning-position)))
      (code-review-minimal--open-input-overlay line line note-id note-body))))

;;;###autoload
(defun code-review-minimal-refresh ()
  "Re-fetch and redisplay all comments."
  (interactive)
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (unless code-review-minimal--mr-iid
    (user-error "code-review-minimal: no MR IID set"))
  (code-review-minimal--assert-token code-review-minimal--current-backend)
  (code-review-minimal--fetch-comments))

;;;###autoload
(defun code-review-minimal-resolve-comment ()
  "Mark the comment at point as resolved."
  (interactive)
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (let ((ov (code-review-minimal--overlay-at-point)))
    (unless ov
      (user-error "code-review-minimal: no comment overlay on this line"))
    (let ((already (overlay-get ov 'code-review-minimal-resolved)))
      (when (eq already t)
        (user-error "code-review-minimal: comment is already resolved"))
      (code-review-minimal--assert-token code-review-minimal--current-backend)
      (code-review-minimal--resolve-comment ov))))

;;;; ─── Minor Mode ────────────────────────────────────────────────────────────

(defvar code-review-minimal-mode-map
  (make-sparse-keymap)
  "Keymap for `code-review-minimal-mode'.")

;;;###autoload
(define-minor-mode code-review-minimal-mode
  "Minor mode for reviewing code inline using overlays.

Typically you start a session with:
  M-x code-review-minimal-review-url

which accepts a full MR/PR URL, auto-detects the backend, and enables
this mode.  The mode can also be toggled directly; if no MR is cached it
will prompt for a URL via `code-review-minimal-review-url'.

Commands:
  `code-review-minimal-review-url'        - start review from a URL (main entry point)
  `code-review-minimal-add-comment'       - add comment for selected region
  `code-review-minimal-edit-comment'      - edit comment at point
  `code-review-minimal-refresh'           - re-fetch comments
  `code-review-minimal-resolve-comment'   - resolve comment at point
  `code-review-minimal-set-backend-for-repo' - change backend for this repo"
  :lighter " CR"
  :keymap code-review-minimal-mode-map
  (if code-review-minimal-mode
      (progn
        ;; Determine backend
        (code-review-minimal--ensure-backend)
        (message "code-review-minimal: using %s backend" code-review-minimal--current-backend)
        ;; Get token for backend
        (code-review-minimal--assert-token code-review-minimal--current-backend)
        ;; Get MR IID — if not already set via review-url, ask for a URL now
        (unless code-review-minimal--mr-iid
          (let ((cached (code-review-minimal--load-cached-iid)))
            (if cached
                (progn
                  (setq code-review-minimal--mr-iid cached)
                  (message "code-review-minimal: using cached MR IID !%d" cached))
              (call-interactively #'code-review-minimal-review-url)
              ;; review-url already fetches comments and handles the rest; bail out
              (setq code-review-minimal-mode nil)
              (cl-return-from nil))))
        ;; Fetch comments
        (code-review-minimal--fetch-comments))
    ;; Disable
    (code-review-minimal--clear-overlays)
    (when code-review-minimal--input-overlay
      (code-review-minimal--cancel-comment))
    (setq code-review-minimal--mr-iid nil
          code-review-minimal--mr-id nil
          code-review-minimal--project-info nil
          code-review-minimal--current-backend nil)))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal)

;;; code-review-minimal.el ends here
