;;; code-review-minimal-codeberg.el --- Codeberg backend for code-review-minimal -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review

;;; Commentary:
;;
;; Codeberg backend for code-review-minimal.
;; Handles PR comment fetching, posting, updating, and deleting via the
;; Gitea REST API v1 (Codeberg runs Forgejo/Gitea).
;;
;; Authentication:
;;   Tokens are read exclusively from authinfo/netrc.  Add an entry to
;;   ~/.authinfo (or ~/.authinfo.gpg):
;;     machine codeberg.org login ^crm password <token>
;;   For self-hosted Gitea instances, use the host from
;;   `code-review-minimal-codeberg-api-url'.
;;
;; HTTP layer: Emacs built-in `url-retrieve' with an Authorization: token
;; header.  The Gitea API v1 is wire-compatible with GitHub for review
;; comments, but we use url-retrieve directly to avoid any ghub assumptions.
;;
;; Backend contract:
;;   :fetch  (callback)                — calls (callback THREADS)
;;   :post   (beg end body on-success) — calls (on-success) on success
;;   :update (note-id body on-success) — calls (on-success) on success
;;   :resolve (ov on-success)          — no-op (Gitea has no resolve API)

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'cl-lib)
(require 'subr-x)
(require 'code-review-minimal-backend)

;;;; ─── Codeberg Remote Parsing ────────────────────────────────────────────────

(defun code-review-minimal--parse-codeberg-repo (remote-url)
  "Parse Codeberg/Gitea REMOTE-URL to get (owner . repo)."
  (when remote-url
    (cond
     ;; SSH: git@codeberg.org:owner/repo.git
     ((string-match
       "git@codeberg\\.org:\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; HTTPS: https://codeberg.org/owner/repo.git
     ((string-match
       "https?://codeberg\\.org/\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; Without .git suffix
     ((string-match
       "https?://codeberg\\.org/\\([^/]+\\)/\\([^/]+\\)/?$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; Self-hosted Gitea SSH
     ((string-match
       "git@[^:]+:\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; Self-hosted Gitea HTTPS
     ((string-match
       "https?://[^/]+/\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url))))))

;;;; ─── Codeberg HTTP Layer ────────────────────────────────────────────────────

(defun code-review-minimal--codeberg-api-url (&rest path-segments)
  "Build a full Codeberg API URL by joining PATH-SEGMENTS onto the base URL."
  (concat
   code-review-minimal-codeberg-api-url
   "/"
   (mapconcat #'identity path-segments "/")))

(defun code-review-minimal--codeberg-http-status ()
  "Return the integer HTTP status from the current url-retrieve buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
      (string-to-number (match-string 1)))))

(defun code-review-minimal--codeberg-response-body ()
  "Return the response body string from the current url-retrieve buffer."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^\\s-*$" nil t)
        (decode-coding-string
         (buffer-substring (point) (point-max)) 'utf-8)
      "")))

(defun code-review-minimal--codeberg-parse-response ()
  "Parse JSON body from the current url-retrieve buffer."
  (let ((body (code-review-minimal--codeberg-response-body)))
    (condition-case err
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'symbol))
          (json-read-from-string body))
      (error
       (message
        "code-review-minimal[codeberg]: JSON parse error: %S\nbody: %s"
        err body)
       nil))))

(defun code-review-minimal--codeberg-http-request
    (method url &optional payload callback)
  "Perform async HTTP METHOD request to Codeberg URL via url-retrieve.
PAYLOAD is an alist JSON-encoded as the request body.
CALLBACK receives the parsed JSON response (or nil on error).
The request is aborted after 30 seconds."
  (let* ((token
          (encode-coding-string
           (or (code-review-minimal--get-token 'codeberg) "") 'utf-8))
         (url-request-method method)
         (url-request-extra-headers
          `(("Authorization" . ,(concat "token " token))
            ("Content-Type" . "application/json; charset=utf-8")))
         (url-request-data
          (when payload
            (let* ((body (json-encode payload))
                   (encoded (encode-coding-string body 'utf-8)))
              encoded)))
         (url-http-attempt-keepalives nil)
         (watchdog-timer nil)
         (buf
          (url-retrieve
           url
           (lambda (status)
             (when watchdog-timer
               (cancel-timer watchdog-timer))
             (let* ((http-status
                     (code-review-minimal--codeberg-http-status))
                    (err (plist-get status :error))
                    (body (code-review-minimal--codeberg-response-body)))
               (cond
                (err
                 (message
                  "code-review-minimal[codeberg]: HTTP error %S (URL: %s)\n  body: %s"
                  err url (substring body 0 (min 400 (length body)))))
                ((and http-status (>= http-status 400))
                 (message
                  "code-review-minimal[codeberg]: HTTP %d for %s\n  body: %s"
                  http-status url
                  (substring body 0 (min 400 (length body)))))
                (t
                 (when callback
                   (funcall
                    callback
                    (code-review-minimal--codeberg-parse-response)))))))
           nil t)))
    (when buf
      (setq watchdog-timer
            (run-with-timer
             30 nil
             (lambda ()
               (when (buffer-live-p buf)
                 (message
                  "code-review-minimal[codeberg]: request timed out after %ds — %s"
                  30 url)
                 (kill-buffer buf))))))
    buf))

;;;; ─── Codeberg Backend Functions ─────────────────────────────────────────────

(defun code-review-minimal--codeberg-ensure-project-info ()
  "Set project info from remote for Codeberg backend."
  (unless (alist-get 'owner code-review-minimal--project-info)
    (let* ((remote (code-review-minimal--git-remote-url))
           (parsed (code-review-minimal--parse-codeberg-repo remote)))
      (if parsed
          (progn
            (message "code-review-minimal: detected repo %s/%s"
                     (car parsed) (cdr parsed))
            (setq code-review-minimal--project-info
                  `((owner . ,(car parsed)) (repo . ,(cdr parsed)))))
        (let ((owner (read-string "Codeberg owner/organization: "))
              (repo (read-string "Codeberg repository name: ")))
          (setq code-review-minimal--project-info
                `((owner . ,owner) (repo . ,repo))))))))

(defun code-review-minimal--codeberg-fetch-comments (callback)
  "Fetch PR comments and call CALLBACK with a list of thread plists (Codeberg)."
  (code-review-minimal--codeberg-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid))
    (message "code-review-minimal: fetching comments for PR #%d ..."
             pr-number)
    (let ((url
           (code-review-minimal--codeberg-api-url
            "repos" owner repo "pulls"
            (number-to-string pr-number) "comments")))
      (code-review-minimal--codeberg-http-request
       "GET" url nil
       (lambda (comments)
         (funcall callback
                  (code-review-minimal--codeberg-normalize-comments
                   comments)))))))

(defun code-review-minimal--codeberg-fetch-diff (callback)
  "Fetch PR changed files and call CALLBACK with a list of change plists (Codeberg).
Each plist has :old-path, :new-path, and :patch (unified diff string)."
  (code-review-minimal--codeberg-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid))
    (message "code-review-minimal: fetching diff for PR #%d ..."
             pr-number)
    (let ((url
           (code-review-minimal--codeberg-api-url
            "repos" owner repo "pulls"
            (number-to-string pr-number) "files")))
      (code-review-minimal--codeberg-http-request
       "GET" url nil
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

(defun code-review-minimal--codeberg-normalize-comments (comments)
  "Convert Codeberg COMMENTS list into the standard thread plist format."
  (mapcar
   (lambda (c)
     (let* ((path (alist-get 'path c))
            (line (or (alist-get 'line c)
                      (alist-get 'original_line c)))
            (body (alist-get 'body c))
            (id (alist-get 'id c))
            (user (alist-get 'login (alist-get 'user c)))
            (created (alist-get 'created_at c))
            (outdated (and (null (alist-get 'line c))
                           (alist-get 'original_line c)))
            (note `((author . ((name . ,user)))
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

(defun code-review-minimal--codeberg-post-comment
    (_beg end body on-success)
  "Post review comment on line at END with BODY (Codeberg), then call ON-SUCCESS.
Codeberg requires the PR head commit SHA for review comments."
  (code-review-minimal--codeberg-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid)
         (rel-path (code-review-minimal--relative-file-path))
         (line (code-review-minimal--line-number-at end)))
    ;; First fetch the PR head commit SHA
    (let ((pr-url
           (code-review-minimal--codeberg-api-url
            "repos" owner repo "pulls" (number-to-string pr-number))))
      (code-review-minimal--codeberg-http-request
       "GET" pr-url nil
       (lambda (pr-data)
         (let ((head-sha (alist-get 'sha (alist-get 'head pr-data))))
           (if (not head-sha)
               (message
                "code-review-minimal: failed to get PR head commit")
             (let ((url
                    (code-review-minimal--codeberg-api-url
                     "repos" owner repo "pulls"
                     (number-to-string pr-number) "comments"))
                   (payload
                    `((body . ,body)
                      (path . ,rel-path)
                      (line . ,line)
                      (side . "RIGHT")
                      (commit_id . ,head-sha))))
               (code-review-minimal--codeberg-http-request
                "POST" url payload
                (lambda (resp)
                  (if (and resp (alist-get 'id resp))
                      (progn
                        (message
                         "code-review-minimal: comment posted (id=%s)"
                         (alist-get 'id resp))
                        (funcall on-success))
                    (message
                     "code-review-minimal: failed to post comment"))))))))))))

(defun code-review-minimal--codeberg-update-comment
    (note-id body on-success)
  "Update NOTE-ID with BODY (Codeberg), then call ON-SUCCESS."
  (code-review-minimal--codeberg-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (url
          (code-review-minimal--codeberg-api-url
           "repos" owner repo "pulls" "comments"
           (number-to-string note-id))))
    (code-review-minimal--codeberg-http-request
     "PATCH" url
     `((body . ,body))
     (lambda (resp)
       (if (and resp (alist-get 'id resp))
           (progn
             (message "code-review-minimal: comment %d updated" note-id)
             (funcall on-success))
         (message "code-review-minimal: failed to update comment %d"
                  note-id))))))

(defun code-review-minimal--codeberg-resolve-comment
    (_note-id _note-body _on-success)
  "No-op resolve for Codeberg.
Gitea/Codeberg does not expose an endpoint for resolving individual review
comments via the REST API.  This function exists only to satisfy the backend
contract."
  (message
   "code-review-minimal: Codeberg review comments are resolved via the web interface"))

(defun code-review-minimal--codeberg-reply-comment
    (note-id body on-success)
  "Post a reply to the review comment NOTE-ID with BODY (Codeberg), then call ON-SUCCESS."
  (code-review-minimal--codeberg-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid)
         (url
          (code-review-minimal--codeberg-api-url
           "repos" owner repo "pulls"
           (number-to-string pr-number) "comments"
           (number-to-string note-id) "replies")))
    (code-review-minimal--codeberg-http-request
     "POST" url
     `((body . ,body))
     (lambda (resp)
       (if (and resp (alist-get 'id resp))
           (progn
             (message "code-review-minimal: reply posted (id=%s)"
                      (alist-get 'id resp))
             (funcall on-success))
         (message "code-review-minimal: failed to post reply"))))))

(defun code-review-minimal--codeberg-delete-comment (note-id on-success)
  "Delete review comment NOTE-ID (Codeberg), then call ON-SUCCESS."
  (code-review-minimal--codeberg-ensure-project-info)
  (let* ((owner (alist-get 'owner code-review-minimal--project-info))
         (repo (alist-get 'repo code-review-minimal--project-info))
         (url
          (code-review-minimal--codeberg-api-url
           "repos" owner repo "pulls" "comments"
           (number-to-string note-id))))
    (code-review-minimal--codeberg-http-request
     "DELETE" url nil
     (lambda (_resp)
       (message "code-review-minimal: comment %d deleted" note-id)
       (funcall on-success)))))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-codeberg)

;;; code-review-minimal-codeberg.el ends here
