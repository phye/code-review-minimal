;;; code-review-minimal.el --- Minimal Code Review with overlay for GitHub/GitLab/Gongfeng -*- lexical-binding: t; -*-

;; Author: phye
;; Version: 0.2.0
;; Keywords: tools, vc, review
;; Package-Requires: ((emacs "27.1") (ghub "3.6"))

;;; Commentary:
;;
;; code-review-minimal is a lightweight minor mode for performing code review
;; directly inside Emacs against GitHub Pull Requests, GitLab Merge Requests,
;; and Gongfeng (工蜂) MRs.
;;
;; Quick start:
;;   1. Add an entry to ~/.authinfo (or ~/.authinfo.gpg) for each forge you use:
;;        machine api.github.com  login ^crm password <github-token>
;;        machine gitlab.com      login ^crm password <gitlab-token>
;;        machine git.woa.com      login ^crm password <gongfeng-token>
;;        machine code.tencent.com login ^crm password <gongfeng-token>
;;      The `^crm' login distinguishes these entries from tokens used by other
;;      Emacs forge tools (e.g. Magit/ghub use `^').
;;      The host is taken from `code-review-minimal-*-api-url', so GitHub
;;      Enterprise and self-hosted GitLab instances work automatically by
;;      setting the appropriate base-URL custom variable.
;;
;;      For multiple accounts on the same host, set the git config first:
;;        git config --global <backend>.user yourname
;;      then use `yourname^crm' as the login in ~/.authinfo.
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
;; Sub-files:
;;   code-review-minimal-backend.el  — config, registry, auth, cache, buffer-local state
;;   code-review-minimal-overlay.el  — comment overlays, input overlay, navigation
;;   code-review-minimal-diff.el     — diff patch parsing and hunk overlay rendering
;;   code-review-minimal-faces.el    — face definitions (light + dark themes)
;;   code-review-minimal-github.el   — GitHub backend
;;   code-review-minimal-gitlab.el   — GitLab backend
;;   code-review-minimal-gongfeng.el — Gongfeng backend
;;
;; License: MIT

;;; Code:

(require 'cl-lib)
(require 'code-review-minimal-backend)
(require 'code-review-minimal-faces)
(require 'code-review-minimal-diff)
(require 'code-review-minimal-overlay)
(require 'code-review-minimal-github)
(require 'code-review-minimal-gitlab)
(require 'code-review-minimal-gongfeng)

;;;; ─── Dispatch ───────────────────────────────────────────────────────────────
;;
;; These functions are the only callers of overlay and re-fetch logic.
;; Backend functions receive callbacks / on-success thunks and must not touch
;; overlays or trigger re-fetches themselves.

(defun code-review-minimal--render-comment-threads (buf rel-path threads)
  "Render comment overlay threads in BUF for REL-PATH from THREADS list."
  (with-current-buffer buf
    (code-review-minimal--clear-overlays)
    (if (null threads)
        (message "code-review-minimal: no comments found")
      (let ((count 0))
        (dolist (th threads)
          (when (and rel-path
                     (string= (plist-get th :path) rel-path)
                     (plist-get th :line)
                     (not (and code-review-minimal-hide-resolved
                               (eq (plist-get th :resolved) t))))
            (code-review-minimal--insert-discussion-overlay
             (plist-get th :line)
             (plist-get th :thread)
             (plist-get th :resolved)
             (plist-get th :note-id))
            (cl-incf count)))
        (message "code-review-minimal: %d thread(s) in this file, %d total."
                 count (length threads))))))

(defun code-review-minimal--refresh-overlays ()
  "Fetch diff and comments via the current backend and render overlays.
Diff hunk overlays are rendered first; comment thread overlays are rendered
after the diff fetch completes (or immediately if diff is disabled/unavailable).
The backend `:fetch-diff' callback receives change plists; `:fetch' receives
thread plists.  Both are filtered to the current file."
  (let ((rel-path (code-review-minimal--relative-file-path))
        (buf      (current-buffer))
        (backend  code-review-minimal--current-backend)
        (iid      code-review-minimal--mr-iid)
        (proj     code-review-minimal--project-info))
    ;; Define the comment-fetch thunk so it can be called from the diff callback
    ;; or directly when diff is skipped.
    (let ((fetch-comments
           (lambda ()
             (funcall (code-review-minimal--backend-prop backend :fetch)
                      (lambda (threads)
                        (code-review-minimal--render-comment-threads buf rel-path threads))))))
      (if (and code-review-minimal-highlight-hunks
               (code-review-minimal--backend-prop backend :fetch-diff))
          ;; Fetch diff first; render hunk overlays, then fetch comment threads.
          (code-review-minimal--fetch-diff-then backend buf iid proj rel-path fetch-comments)
        ;; No diff support or disabled — fetch comments directly.
        (progn
          (funcall fetch-comments))))))

(defun code-review-minimal--post-comment (beg end body)
  "Post a new comment via the current backend, then refresh overlays."
  (let ((buf (current-buffer)))
    (funcall (code-review-minimal--backend-prop
              code-review-minimal--current-backend :post)
             beg end body
             (lambda ()
               (with-current-buffer buf
                 (code-review-minimal--refresh-overlays))))))

(defun code-review-minimal--update-comment (note-id body)
  "Update an existing comment via the current backend, then refresh overlays."
  (let ((buf (current-buffer)))
    (funcall (code-review-minimal--backend-prop
              code-review-minimal--current-backend :update)
             note-id body
             (lambda ()
               (with-current-buffer buf
                 (code-review-minimal--refresh-overlays))))))

(defun code-review-minimal--resolve-comment (ov)
  "Resolve a comment via the current backend, then refresh overlays."
  (let ((buf      (current-buffer))
        (note-id  (overlay-get ov 'code-review-minimal-note-id))
        (note-body (overlay-get ov 'code-review-minimal-body)))
    (funcall (code-review-minimal--backend-prop
              code-review-minimal--current-backend :resolve)
             note-id note-body
             (lambda ()
               (with-current-buffer buf
                 (code-review-minimal--refresh-overlays))))))

(defun code-review-minimal--reply-comment (note-id body)
  "Post a reply to the thread rooted at NOTE-ID via the current backend, then refresh overlays."
  (let ((buf (current-buffer)))
    (funcall (code-review-minimal--backend-prop
              code-review-minimal--current-backend :reply)
             note-id body
             (lambda ()
               (with-current-buffer buf
                 (code-review-minimal--refresh-overlays))))))

(defun code-review-minimal--delete-comment (note-id)
  "Delete the comment NOTE-ID via the current backend, then refresh overlays."
  (let ((buf (current-buffer)))
    (funcall (code-review-minimal--backend-prop
              code-review-minimal--current-backend :delete)
             note-id
             (lambda ()
               (with-current-buffer buf
                 (code-review-minimal--refresh-overlays))))))

(defun code-review-minimal--diff-cache-key (backend iid project-info)
  "Return a cache key for the diff of BACKEND IID PROJECT-INFO."
  (list backend iid project-info))

(defun code-review-minimal--fetch-diff-then (backend buf iid project-info rel-path on-done)
  "Fetch or reuse cached diff for BACKEND IID; render hunk overlays in BUF for REL-PATH.
After hunk overlays are in place, call ON-DONE (a zero-argument function) to
trigger the next rendering step (typically fetching comment threads)."
  (let* ((key (code-review-minimal--diff-cache-key backend iid project-info))
         (cached (gethash key code-review-minimal--diff-cache)))
    (if cached
        (with-current-buffer buf
          (code-review-minimal--clear-hunk-overlays)
          (let ((patch (code-review-minimal--find-patch-for-file cached rel-path)))
            (when patch
              (code-review-minimal--insert-hunk-overlays patch)))
          (funcall on-done))
      (funcall (code-review-minimal--backend-prop backend :fetch-diff)
               (lambda (changes)
                 (puthash key changes code-review-minimal--diff-cache)
                 (with-current-buffer buf
                   (code-review-minimal--clear-hunk-overlays)
                   (let ((patch (code-review-minimal--find-patch-for-file changes rel-path)))
                     (when patch
                       (code-review-minimal--insert-hunk-overlays patch)))
                   (funcall on-done)))))))

;;;; ─── Public Commands ───────────────────────────────────────────────────────

(defun code-review-minimal--all-hunk-positions ()
  "Return a sorted list of (ABS-PATH . LINE) for every hunk in the current MR diff.
ABS-PATH is the absolute path to the new-side file; LINE is the hunk's new-start line.
Returns nil when no diff data is cached yet."
  (let* ((backend  code-review-minimal--current-backend)
         (iid      code-review-minimal--mr-iid)
         (proj     code-review-minimal--project-info)
         (root     (code-review-minimal--git-root))
         ;; Primary: look up by exact cache key
         (changes  (when (and backend iid proj)
                     (gethash (code-review-minimal--diff-cache-key backend iid proj)
                              code-review-minimal--diff-cache)))
         ;; Fallback: scan every cached entry and pick the first whose files
         ;; resolve under the current git root.  This handles the case where
         ;; buffer-local vars are stale or nil (e.g. after navigating to a new
         ;; file that hasn't fully inherited MR state yet).
         (changes  (or changes
                       (when root
                         (let ((found nil))
                           (maphash
                            (lambda (_k v)
                              (unless found
                                (let* ((first (car v))
                                       (rel   (or (plist-get first :new-path)
                                                  (plist-get first :old-path))))
                                  (when (and rel
                                             (file-exists-p
                                              (expand-file-name rel root)))
                                    (setq found v)))))
                            code-review-minimal--diff-cache)
                           found))))
         (result   nil))
    (if (not (and changes root))
        (progn
          (when (called-interactively-p 'any)
            (message "code-review-minimal: diff not yet cached — run `code-review-minimal-review-url' first"))
          nil)
      (dolist (c changes)
        (let* ((rel   (or (plist-get c :new-path) (plist-get c :old-path)))
               (abs   (expand-file-name rel root))
               (patch (plist-get c :patch)))
          (when (and rel patch)
            (dolist (hunk (code-review-minimal--parse-patch patch))
              (push (cons abs (plist-get hunk :new-start)) result)))))
      (sort result (lambda (a b)
                     (or (string< (car a) (car b))
                         (and (string= (car a) (car b))
                              (< (cdr a) (cdr b)))))))))

(defun code-review-minimal--current-hunk-key ()
  "Return a (ABS-PATH . LINE) key representing the current position.
LINE is the current line number; ABS-PATH is the current buffer's absolute path."
  (cons (expand-file-name (or buffer-file-name "")) (line-number-at-pos)))

(defun code-review-minimal--goto-hunk (abs-path line)
  "Visit ABS-PATH (opening it if needed) and move point to LINE.
Ensures `code-review-minimal-mode' is active in the target buffer.
MR state (backend, iid, project-info) is propagated from the calling buffer
into the target buffer so that hunk navigation continues to work there."
  ;; Capture MR state from the calling buffer before any buffer switch.
  (let ((src-backend code-review-minimal--current-backend)
        (src-iid     code-review-minimal--mr-iid)
        (src-mr-id   code-review-minimal--mr-id)
        (src-proj    code-review-minimal--project-info))
    (unless (and buffer-file-name
                 (string= (expand-file-name buffer-file-name) abs-path))
      (find-file abs-path))
    ;; Propagate MR state into the new buffer if it is not already set.
    (when (and src-backend (not code-review-minimal--current-backend))
      (setq code-review-minimal--current-backend src-backend))
    (when (and src-iid (not code-review-minimal--mr-iid))
      (setq code-review-minimal--mr-iid src-iid))
    (when (and src-mr-id (not code-review-minimal--mr-id))
      (setq code-review-minimal--mr-id src-mr-id))
    (when (and src-proj (not code-review-minimal--project-info))
      (setq code-review-minimal--project-info src-proj))
    (unless (bound-and-true-p code-review-minimal-mode)
      (code-review-minimal-mode 1))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;###autoload
(defun code-review-minimal-next-hunk ()
  "Move point to the next diff hunk, opening other files in the MR if needed.
Wraps around to the first hunk after the last one."
  (interactive)
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (let* ((all  (code-review-minimal--all-hunk-positions))
         (cur  (code-review-minimal--current-hunk-key))
         (_ (message "[crm-hunk] next-hunk: backend=%S iid=%S cache-size=%d all-count=%d cur=%S"
                     code-review-minimal--current-backend
                     code-review-minimal--mr-iid
                     (hash-table-count code-review-minimal--diff-cache)
                     (length all)
                     cur))
         (next (or (cl-find-if (lambda (entry)
                                 (or (string< (car cur) (car entry))
                                     (and (string= (car cur) (car entry))
                                          (< (cdr cur) (cdr entry)))))
                               all)
                   ;; wrap around to first hunk
                   (car all))))
    (if next
        (code-review-minimal--goto-hunk (car next) (cdr next))
      (user-error "code-review-minimal: diff not cached yet — run `code-review-minimal-review-url' first"))))

;;;###autoload
(defun code-review-minimal-previous-hunk ()
  "Move point to the previous diff hunk, opening other files in the MR if needed.
Wraps around to the last hunk before the first one."
  (interactive)
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (let* ((all  (code-review-minimal--all-hunk-positions))
         (cur  (code-review-minimal--current-hunk-key))
         (prev (or (cl-find-if (lambda (entry)
                                 (or (string< (car entry) (car cur))
                                     (and (string= (car entry) (car cur))
                                          (< (cdr entry) (cdr cur)))))
                               (reverse all))
                   ;; wrap around to last hunk
                   (car (last all)))))
    (if prev
        (code-review-minimal--goto-hunk (car prev) (cdr prev))
      (user-error "code-review-minimal: diff not cached yet — run `code-review-minimal-review-url' first"))))

(defun code-review-minimal--checkout-branch-for-review ()
  "Prompt the user to checkout a branch for the current MR/PR review.
Lists both local and remote-tracking branches.  If a remote-tracking ref
is selected and plain checkout fails, a local tracking branch is created
automatically.  Reverts the current buffer after a successful checkout.
Skips silently when the user accepts the empty default."
  (let* ((root (or (code-review-minimal--git-root) default-directory))
         (default-directory root)
         (local-branches
          (split-string
           (shell-command-to-string
            "git branch '--format=%(refname:short)' 2>/dev/null")
           "\n" t))
         (remote-branches
          (split-string
           (shell-command-to-string
            "git branch -r '--format=%(refname:short)' 2>/dev/null")
           "\n" t))
         (all-branches (delete-dups (append local-branches remote-branches)))
         (branch
          (completing-read "Checkout branch for review (RET to skip): "
                           all-branches nil nil nil nil "")))
    (unless (string-empty-p branch)
      ;; Try plain checkout first (handles local branches and already-fetched
      ;; remote-tracking refs like "origin/foo" via DWIM).
      (let ((result (shell-command
                     (format "git checkout %s"
                             (shell-quote-argument branch)))))
        (when (not (zerop result))
          ;; Plain checkout failed.  If the name looks like a remote-tracking
          ;; ref (e.g. "origin/feature"), create a local tracking branch.
          (let* ((local-name
                  (when (string-match "^[^/]+/\\(.+\\)$" branch)
                    (match-string 1 branch)))
                 (retry-result
                  (when local-name
                    (shell-command
                     (format "git checkout -b %s --track %s"
                             (shell-quote-argument local-name)
                             (shell-quote-argument branch))))))
            (if (and retry-result (zerop retry-result))
                (setq branch local-name)
              (user-error
               "code-review-minimal: git checkout %s failed — aborting review"
               branch))))
        (message "code-review-minimal: checked out branch %s" branch)
        ;; Revert the buffer so its content matches the newly-checked-out
        ;; file; the diff's new-file line numbers reference this version.
        (when (and buffer-file-name (file-readable-p buffer-file-name))
          (revert-buffer t t))))))

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
      (setq code-review-minimal--mr-iid          iid
            code-review-minimal--mr-id           nil
            code-review-minimal--project-info    projinfo)
      (when backend
        (setq code-review-minimal--current-backend backend)
        (code-review-minimal--save-backend backend))
      (code-review-minimal--save-iid iid)
      ;; Invalidate diff cache for this MR so we always start fresh
      (remhash (code-review-minimal--diff-cache-key
                (or backend code-review-minimal--current-backend)
                iid projinfo)
               code-review-minimal--diff-cache)
      (code-review-minimal--ensure-backend)
      (code-review-minimal--assert-token code-review-minimal--current-backend)
      (message "code-review-minimal: reviewing !%d on %s [%s]" iid
               (or (alist-get 'project-id projinfo)
                   (format "%s/%s" (alist-get 'owner projinfo) (alist-get 'repo projinfo)))
               code-review-minimal--current-backend)
      (code-review-minimal--checkout-branch-for-review)
      ;; Enable mode (which refreshes overlays) or just refresh if already on
      (if (bound-and-true-p code-review-minimal-mode)
          (code-review-minimal--refresh-overlays)
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
  (code-review-minimal--refresh-overlays))

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

;;;###autoload
(defun code-review-minimal-reply-comment ()
  "Reply to the code review comment thread at point."
  (interactive)
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (let ((ov (code-review-minimal--overlay-at-point)))
    (unless ov
      (user-error "code-review-minimal: no comment overlay on this line"))
    (code-review-minimal--assert-token code-review-minimal--current-backend)
    (let ((note-id (overlay-get ov 'code-review-minimal-note-id))
          (line    (line-beginning-position)))
      (code-review-minimal--open-input-overlay line line nil nil note-id))))

;;;###autoload
(defun code-review-minimal-delete-comment ()
  "Delete the code review comment at point."
  (interactive)
  (unless (bound-and-true-p code-review-minimal-mode)
    (user-error "code-review-minimal: please enable `code-review-minimal-mode' first"))
  (let ((ov (code-review-minimal--overlay-at-point)))
    (unless ov
      (user-error "code-review-minimal: no comment overlay on this line"))
    (code-review-minimal--assert-token code-review-minimal--current-backend)
    (let ((note-id (overlay-get ov 'code-review-minimal-note-id)))
      (when (yes-or-no-p (format "Delete comment %s? " note-id))
        (code-review-minimal--delete-comment note-id)))))

;;;; ─── Minor Mode ────────────────────────────────────────────────────────────

(defvar code-review-minimal-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-d") #'code-review-minimal-view-removed-lines)
    m)
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
  `code-review-minimal-reply-comment'     - reply to comment thread at point
  `code-review-minimal-delete-comment'    - delete comment at point
  `code-review-minimal-refresh'           - re-fetch comments
  `code-review-minimal-next-hunk'          - go to next diff hunk (cross-file)
  `code-review-minimal-previous-hunk'      - go to previous diff hunk (cross-file)
  `code-review-minimal-view-removed-lines' - view full removed block at point
  `code-review-minimal-resolve-comment'   - resolve comment at point
  `code-review-minimal-set-backend-for-repo' - change backend for this repo
  `code-review-minimal-finish-review'     - end session and clear all state/cache"
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
              ;; review-url already refreshes overlays and handles the rest; bail out
              (setq code-review-minimal-mode nil)
              (cl-return-from nil))))
        ;; Set left margin for diff fringe indicators
        (dolist (win (get-buffer-window-list (current-buffer) nil t))
          (let ((margins (window-margins win)))
            (set-window-margins win 2 (cdr margins))))
        ;; Refresh diff and comment overlays
        (code-review-minimal--refresh-overlays))
    ;; Disable
    (code-review-minimal--clear-overlays)
    (code-review-minimal--clear-hunk-overlays)
    (when code-review-minimal--input-overlay
      (code-review-minimal--cancel-comment))
    (dolist (win (get-buffer-window-list (current-buffer) nil t))
      (let ((margins (window-margins win)))
        (set-window-margins win 0 (cdr margins))))
    (setq code-review-minimal--mr-iid nil
          code-review-minimal--mr-id nil
          code-review-minimal--project-info nil
          code-review-minimal--current-backend nil)))

;;;###autoload
(defun code-review-minimal-finish-review ()
  "Finish the current review session and clean up all state.

Disables `code-review-minimal-mode' in every buffer that has it active,
clears the diff cache, the IID/backend in-memory caches, and removes the
per-repo cache files (.git/code-review-minimal-iid and
.git/code-review-minimal-backend) so the next session starts fresh."
  (interactive)
  (let ((root (code-review-minimal--git-root)))
    ;; 1. Disable mode in all live buffers for this repo.
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (bound-and-true-p code-review-minimal-mode)
          (code-review-minimal-mode -1))))
    ;; 2. Clear the global diff cache entirely.
    (clrhash code-review-minimal--diff-cache)
    ;; 3. Clear the in-memory IID and backend caches.
    (clrhash code-review-minimal--iid-cache)
    (clrhash code-review-minimal--backend-cache)
    ;; 4. Remove the per-repo cache files so IID/backend are not reused next time.
    (when root
      (dolist (fname '("code-review-minimal-iid" "code-review-minimal-backend"))
        (let ((file (expand-file-name fname (expand-file-name ".git" root))))
          (when (file-exists-p file)
            (delete-file file)))))
    (message "code-review-minimal: review session finished and all state cleared.")))


(provide 'code-review-minimal)

;;; code-review-minimal.el ends here
