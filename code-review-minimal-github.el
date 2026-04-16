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
;;   For GitHub Enterprise, use the host from `code-review-minimal-github-base-url'.
;;
;; HTTP layer: ghub (`ghub-request'), Authorization: Bearer header.
;;
;; Note: GitHub does not expose an API endpoint to mark review comments as
;; resolved; `code-review-minimal--github-resolve-comment' is therefore a
;; no-op that directs the user to the web interface.

;;; Code:

(require 'ghub)

;; Declare variables and functions from the parent package to avoid
;; circular-require warnings.  These are always present at runtime because
;; code-review-minimal.el loads this file.
(defvar code-review-minimal--project-info)
(defvar code-review-minimal--mr-iid)
(defvar code-review-minimal--mr-id)
(defvar code-review-minimal-github-base-url)
(declare-function code-review-minimal--git-remote-url            "code-review-minimal")
(declare-function code-review-minimal--get-token                 "code-review-minimal")
(declare-function code-review-minimal--assert-token              "code-review-minimal")
(declare-function code-review-minimal--relative-file-path        "code-review-minimal")
(declare-function code-review-minimal--line-number-at            "code-review-minimal")
(declare-function code-review-minimal--clear-overlays            "code-review-minimal")
(declare-function code-review-minimal--insert-discussion-overlay "code-review-minimal")

;;;; ─── GitHub Remote Parsing ─────────────────────────────────────────────────

(defun code-review-minimal--parse-github-repo (remote-url)
  "Parse GitHub REMOTE-URL to get (owner . repo)."
  (when remote-url
    (cond
     ;; SSH: git@github.com:owner/repo.git
     ((string-match "git@github\\.com:\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; HTTPS: https://github.com/owner/repo.git
     ((string-match "https?://github\\.com/\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; Without .git suffix
     ((string-match "https?://github\\.com/\\([^/]+\\)/\\([^/]+\\)/?$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; GitHub Enterprise SSH
     ((string-match "git@[^:]+:\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url)))
     ;; GitHub Enterprise HTTPS
     ((string-match "https?://[^/]+/\\([^/]+\\)/\\(.*\\)\\.git$" remote-url)
      (cons (match-string 1 remote-url) (match-string 2 remote-url))))))

;;;; ─── GitHub HTTP Layer ──────────────────────────────────────────────────────

(defun code-review-minimal--github-api-url (&rest path-segments)
  "Build a full GitHub API URL by joining PATH-SEGMENTS onto the base URL."
  (concat code-review-minimal-github-base-url
          "/" (mapconcat #'identity path-segments "/")))

(defun code-review-minimal--github-http-request (method url &optional payload callback)
  "Perform async HTTP METHOD request to GitHub URL via ghub.
PAYLOAD is an alist sent as JSON body.  CALLBACK receives parsed JSON."
  (code-review-minimal--assert-token 'github)
  (let* ((token    (code-review-minimal--get-token 'github))
         (host     (replace-regexp-in-string "^https?://" ""
                                             code-review-minimal-github-base-url))
         (resource (substring url (length code-review-minimal-github-base-url)))
         (wrapped-callback
          (when callback
            (lambda (result _headers _status _req)
              (funcall callback result)))))
    (ghub-request method resource nil
                  :auth      token
                  :host      host
                  :payload   payload
                  :callback  wrapped-callback
                  :errorback
                  (lambda (err _headers _status _req)
                    (message "code-review-minimal[github]: HTTP error for %s: %S" url err)))))

;;;; ─── GitHub Backend Functions ──────────────────────────────────────────────

(defun code-review-minimal--github-ensure-project-info ()
  "Set project info from remote for GitHub backend."
  (unless (alist-get 'owner code-review-minimal--project-info)
    (let* ((remote (code-review-minimal--git-remote-url))
           (parsed (code-review-minimal--parse-github-repo remote)))
      (if parsed
          (progn
            (message "code-review-minimal: detected repo %s/%s" (car parsed) (cdr parsed))
            (setq code-review-minimal--project-info
                  `((owner . ,(car parsed))
                    (repo  . ,(cdr parsed)))))
        (let ((owner (read-string "GitHub owner/organization: "))
              (repo  (read-string "GitHub repository name: ")))
          (setq code-review-minimal--project-info
                `((owner . ,owner)
                  (repo  . ,repo))))))))

(defun code-review-minimal--github-fetch-comments ()
  "Fetch PR comments and render overlays (GitHub)."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner     (alist-get 'owner code-review-minimal--project-info))
         (repo      (alist-get 'repo  code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid)
         (rel-path  (code-review-minimal--relative-file-path))
         (buf       (current-buffer)))
    (message "code-review-minimal: fetching comments for PR #%d ..." pr-number)
    (let ((url (code-review-minimal--github-api-url
                "repos" owner repo "pulls" (number-to-string pr-number) "comments")))
      (code-review-minimal--github-http-request
       "GET" url nil
       (lambda (comments)
         (with-current-buffer buf
           (code-review-minimal--clear-overlays)
           (code-review-minimal--github-process-comments comments rel-path)))))))

(defun code-review-minimal--github-process-comments (comments rel-path)
  "Process GitHub COMMENTS and create overlays for REL-PATH."
  (let ((count 0))
    (dolist (c comments)
      (let ((path    (alist-get 'path       c))
            (line    (alist-get 'line       c))
            (body    (alist-get 'body       c))
            (id      (alist-get 'id         c))
            (user    (alist-get 'login (alist-get 'user c)))
            (created (alist-get 'created_at c)))
        (when (and path line (string= path rel-path))
          (let* ((note   `((author . ((name . ,user)))
                            (body . ,body)
                            (created_at . ,created)))
                 (thread (list note)))
            (code-review-minimal--insert-discussion-overlay line thread nil id)
            (cl-incf count)))))
    (message "code-review-minimal: %d comment(s) in this file" count)))

(defun code-review-minimal--github-post-comment (_beg end body)
  "Post review comment on line at END with BODY (GitHub).
GitHub requires the PR head commit SHA for review comments."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner     (alist-get 'owner code-review-minimal--project-info))
         (repo      (alist-get 'repo  code-review-minimal--project-info))
         (pr-number code-review-minimal--mr-iid)
         (rel-path  (code-review-minimal--relative-file-path))
         (line      (code-review-minimal--line-number-at end))
         (src-buf   (current-buffer)))
    ;; First fetch the PR head commit SHA
    (let ((pr-url (code-review-minimal--github-api-url
                   "repos" owner repo "pulls" (number-to-string pr-number))))
      (code-review-minimal--github-http-request
       "GET" pr-url nil
       (lambda (pr-data)
         (let ((head-sha (alist-get 'sha (alist-get 'head pr-data))))
           (if (not head-sha)
               (message "code-review-minimal: failed to get PR head commit")
             (let ((url     (code-review-minimal--github-api-url
                             "repos" owner repo "pulls"
                             (number-to-string pr-number) "comments"))
                   (payload `((body      . ,body)
                              (path      . ,rel-path)
                              (line      . ,line)
                              (side      . "RIGHT")
                              (commit_id . ,head-sha))))
               (code-review-minimal--github-http-request
                "POST" url payload
                (lambda (resp)
                  (if (and resp (alist-get 'id resp))
                      (progn
                        (message "code-review-minimal: comment posted (id=%s)"
                                 (alist-get 'id resp))
                        (with-current-buffer src-buf
                          (code-review-minimal--github-fetch-comments)))
                    (message "code-review-minimal: failed to post comment"))))))))))))

(defun code-review-minimal--github-update-comment (note-id body)
  "Update NOTE-ID with BODY (GitHub)."
  (code-review-minimal--github-ensure-project-info)
  (let* ((owner   (alist-get 'owner code-review-minimal--project-info))
         (repo    (alist-get 'repo  code-review-minimal--project-info))
         (src-buf (current-buffer))
         (url     (code-review-minimal--github-api-url
                   "repos" owner repo "pulls" "comments"
                   (number-to-string note-id))))
    (code-review-minimal--github-http-request
     "PATCH" url `((body . ,body))
     (lambda (resp)
       (if (and resp (alist-get 'id resp))
           (progn
             (message "code-review-minimal: comment %d updated" note-id)
             (with-current-buffer src-buf
               (code-review-minimal--github-fetch-comments)))
         (message "code-review-minimal: failed to update comment %d" note-id))))))

(defun code-review-minimal--github-resolve-comment (_ov)
  "Resolve comment overlay OV (GitHub).
GitHub does not provide a REST API for resolving review comments;
use the web interface instead."
  (message "code-review-minimal: GitHub review comments are resolved via the web interface"))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-github)

;;; code-review-minimal-github.el ends here
