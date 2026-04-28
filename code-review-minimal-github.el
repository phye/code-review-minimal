;;; code-review-minimal-github.el --- GitHub backend for code-review-minimal -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review

;;; Commentary:
;;
;; GitHub backend for code-review-minimal.
;; Handles PR review-comment fetching, posting, and updating via the
;; GitHub REST API v3.
;;
;; Authentication:
;;   Tokens are read exclusively from authinfo/netrc.  Add an entry to
;;   ~/.authinfo (or ~/.authinfo.gpg):
;;     machine api.github.com login ^crm password <token>
;;   For GitHub Enterprise, use the host from `code-review-minimal-github-api-url'.
;;
;; HTTP layer: ghub (`ghub-request'), Authorization: Bearer header.
;;
;; Backend contract:
;;   :fetch  (callback)            — calls (callback THREADS) where THREADS is a
;;                                   list of plists; see `code-review-minimal-register-backend'.
;;   :post   (beg end body on-success) — calls (on-success) on success.
;;   :update (note-id body on-success) — calls (on-success) on success.
;;   :resolve (ov on-success)          — GitHub has no resolve API; shows a
;;                                       message and does NOT call on-success.

;;; Code:

(require 'ghub)
(require 'code-review-minimal-backend)

;;;; ─── GitHub Remote Parsing ─────────────────────────────────────────────────

(defun code-review-minimal--parse-github-repo (remote-url)
  "Parse GitHub REMOTE-URL to get (owner . repo)."
  (when remote-url
    (cond
     ;; SSH: git@github.com:owner/repo.git
     ((string-match
       "git@github\\.com:\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; HTTPS: https://github.com/owner/repo.git
     ((string-match
       "https?://github\\.com/\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; Without .git suffix
     ((string-match
       "https?://github\\.com/\\([^/]+\\)/\\([^/]+\\)/?$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; GitHub Enterprise SSH
     ((string-match
       "git@[^:]+:\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; GitHub Enterprise HTTPS
     ((string-match
       "https?://[^/]+/\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons
       (match-string 1 remote-url) (match-string 2 remote-url))))))

;;;; ─── GitHub HTTP Layer ──────────────────────────────────────────────────────

(defun code-review-minimal--github-api-url (&rest path-segments)
  "Build a full GitHub API URL by joining PATH-SEGMENTS onto the base URL."
  (concat
   code-review-minimal-github-api-url
   "/"
   (mapconcat #'identity path-segments "/")))

(defun code-review-minimal--github-http-request
    (method url &optional payload callback)
  "Perform async HTTP METHOD request to GitHub URL via ghub.
PAYLOAD is an alist sent as JSON body.  CALLBACK receives parsed JSON."
  (code-review-minimal--assert-token 'github)
  (let* ((token (code-review-minimal--get-token 'github))
         (host
          (replace-regexp-in-string
           "^https?://" "" code-review-minimal-github-api-url))
         (resource
          (substring url (length code-review-minimal-github-api-url)))
         (wrapped-callback
          (when callback
            (lambda (result _headers _status _req)
              (funcall callback result)))))
    (ghub-request
     method resource nil
     :auth token
     :host host
     :payload payload
     :callback wrapped-callback
     :errorback
     (lambda (err _headers _status _req)
       (message "code-review-minimal[github]: HTTP error for %s: %S"
                url err)))))

;;;; ─── GitHub Backend Functions ──────────────────────────────────────────────

(defun code-review-minimal--github-ensure-project-info ()
  "Set project info from remote for GitHub backend."
  (unless (alist-get 'owner code-review-minimal--project-info)
    (let* ((remote (code-review-minimal--git-remote-url))
           (parsed (code-review-minimal--parse-github-repo remote)))
      (if parsed
          (progn
            (message "code-review-minimal: detected repo %s/%s"
                     (car parsed)
                     (cdr parsed))
            (setq code-review-minimal--project-info
                  `((owner . ,(car parsed)) (repo . ,(cdr parsed)))))
        (let ((owner (read-string "GitHub owner/organization: "))
              (repo (read-string "GitHub repository name: ")))
          (setq code-review-minimal--project-info
                `((owner . ,owner) (repo . ,repo))))))))

(defun code-review-minimal--github-fetch-comments (callback)
  "Fetch PR comments and call CALLBACK with a list of thread plists (GitHub)."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid))
    (message "code-review-minimal: fetching comments for PR #%d ..."
             pr-number)
    (let ((url
           (code-review-minimal--github-api-url
            "repos"
            owner
            repo
            "pulls"
            (number-to-string pr-number)
            "comments")))
      (code-review-minimal--github-http-request
       "GET" url
       nil
       (lambda (comments)
         (funcall callback
                  (code-review-minimal--github-normalize-comments
                   comments)))))))

(defun code-review-minimal--github-fetch-diff (callback)
  "Fetch PR changed files and call CALLBACK with a list of change plists (GitHub).
Each plist has :old-path, :new-path, and :patch (unified diff string)."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid))
    (message "code-review-minimal: fetching diff for PR #%d ..."
             pr-number)
    (let ((url
           (code-review-minimal--github-api-url
            "repos"
            owner
            repo
            "pulls"
            (number-to-string pr-number)
            "files")))
      (code-review-minimal--github-http-request
       "GET" url
       nil
       (lambda (files)
         (funcall callback
                  (mapcar
                   (lambda (f)
                     (list
                      :old-path
                      (or (alist-get 'previous_filename f)
                          (alist-get 'filename f))
                      :new-path (alist-get 'filename f)
                      :patch (alist-get 'patch f)))
                   (or files '()))))))))

(defun code-review-minimal--github-normalize-comments (comments)
  "Convert GitHub COMMENTS list into the standard thread plist format."
  (mapcar
   (lambda (c)
     (let* ((path (alist-get 'path c))
            (line
             (or (alist-get 'line c) (alist-get 'original_line c)))
            (body (alist-get 'body c))
            (id (alist-get 'id c))
            (user (alist-get 'login (alist-get 'user c)))
            (created (alist-get 'created_at c))
            (outdated
             (and (null (alist-get 'line c))
                  (alist-get 'original_line c)))
            (note
             `((author . ((name . ,user)))
               (body . ,body)
               (created_at . ,created))))
       (list
        :path path
        :line line
        :thread (list note)
        :resolved nil
        :outdated outdated
        :note-id id)))
   (or comments '())))

(defun code-review-minimal--github-post-comment
    (_beg end body on-success)
  "Post review comment on line at END with BODY (GitHub), then call ON-SUCCESS.
GitHub requires the PR head commit SHA for review comments."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid)
         (rel-path (code-review-minimal--relative-file-path))
         (line (code-review-minimal--line-number-at end)))
    ;; First fetch the PR head commit SHA
    (let ((pr-url
           (code-review-minimal--github-api-url
            "repos" owner repo "pulls" (number-to-string pr-number))))
      (code-review-minimal--github-http-request
       "GET" pr-url
       nil
       (lambda (pr-data)
         (let ((head-sha
                (alist-get 'sha (alist-get 'head pr-data))))
           (if (not head-sha)
               (message
                "code-review-minimal: failed to get PR head commit")
             (let ((url
                    (code-review-minimal--github-api-url
                     "repos"
                     owner
                     repo
                     "pulls"
                     (number-to-string pr-number)
                     "comments"))
                   (payload
                    `((body . ,body)
                      (path . ,rel-path)
                      (line . ,line)
                      (side . "RIGHT")
                      (commit_id . ,head-sha))))
               (code-review-minimal--github-http-request
                "POST"
                url
                payload
                (lambda (resp)
                  (if (and resp
                           (alist-get 'id resp))
                      (progn
                        (message
                         "code-review-minimal: comment posted (id=%s)"
                         (alist-get 'id resp))
                        (funcall on-success))
                    (message
                     "code-review-minimal: failed to post comment"))))))))))))

(defun code-review-minimal--github-update-comment
    (note-id body on-success)
  "Update NOTE-ID with BODY (GitHub), then call ON-SUCCESS."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (url
          (code-review-minimal--github-api-url
           "repos"
           owner
           repo
           "pulls"
           "comments"
           (number-to-string note-id))))
    (code-review-minimal--github-http-request
     "PATCH" url
     `((body . ,body))
     (lambda (resp)
       (if (and resp
                (alist-get 'id resp))
           (progn
             (message "code-review-minimal: comment %d updated"
                      note-id)
             (funcall on-success))
         (message "code-review-minimal: failed to update comment %d"
                  note-id))))))

(defun code-review-minimal--github-resolve-comment
    (_note-id _note-body _on-success)
  "No-op resolve for GitHub (NOTE-ID, NOTE-BODY, ON-SUCCESS are unused).
GitHub's REST API does not expose an endpoint for resolving individual review
comments; resolution must be performed through the web interface.  This
function exists only to satisfy the backend contract."
  (message
   "code-review-minimal: GitHub review comments are resolved via the web interface"))

(defun code-review-minimal--github-reply-comment
    (note-id body on-success)
  "Post a reply to the review comment NOTE-ID with BODY (GitHub), then call ON-SUCCESS."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid)
         (url
          (code-review-minimal--github-api-url
           "repos"
           owner
           repo
           "pulls"
           (number-to-string pr-number)
           "comments"
           (number-to-string note-id)
           "replies")))
    (code-review-minimal--github-http-request
     "POST" url
     `((body . ,body))
     (lambda (resp)
       (if (and resp
                (alist-get 'id resp))
           (progn
             (message "code-review-minimal: reply posted (id=%s)"
                      (alist-get 'id resp))
             (funcall on-success))
         (message "code-review-minimal: failed to post reply"))))))

(defun code-review-minimal--github-delete-comment (note-id on-success)
  "Delete review comment NOTE-ID (GitHub), then call ON-SUCCESS."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (url
          (code-review-minimal--github-api-url
           "repos"
           owner
           repo
           "pulls"
           "comments"
           (number-to-string note-id))))
    (code-review-minimal--github-http-request
     "DELETE" url
     nil
     (lambda (_resp)
       (message "code-review-minimal: comment %d deleted" note-id)
       (funcall on-success)))))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-github)

;;; code-review-minimal-github.el ends here
