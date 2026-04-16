;;; code-review-minimal-gitlab.el --- GitLab backend for code-review-minimal -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review

;;; Commentary:
;;
;; GitLab backend for code-review-minimal.
;; Handles MR comment fetching, posting, updating, and resolving via the
;; GitLab REST API v4.
;;
;; Authentication:
;;   Tokens are read exclusively from authinfo/netrc.  Add an entry to
;;   ~/.authinfo (or ~/.authinfo.gpg):
;;     machine gitlab.com login ^crm password <token>
;;   For self-hosted instances, use the host from `code-review-minimal-gitlab-base-url'.
;;
;; HTTP layer: ghub (`ghub-request' with :forge 'gitlab), PRIVATE-TOKEN header.
;;
;; This backend is for standard GitLab instances (API v4) only.  For Gongfeng
;; (Tencent's internal GitLab at git.woa.com, which runs a custom API v3
;; not wire-compatible with v4), see code-review-minimal-gongfeng.el.

;;; Code:

(require 'ghub)

;; Declare variables and functions from the parent package to avoid
;; circular-require warnings.  These are always present at runtime because
;; code-review-minimal.el loads this file.
(defvar code-review-minimal--project-info)
(defvar code-review-minimal--mr-iid)
(defvar code-review-minimal--mr-id)
(defvar code-review-minimal-gitlab-base-url)
(declare-function code-review-minimal--git-remote-url            "code-review-minimal")
(declare-function code-review-minimal--get-token                 "code-review-minimal")
(declare-function code-review-minimal--assert-token              "code-review-minimal")
(declare-function code-review-minimal--relative-file-path        "code-review-minimal")
(declare-function code-review-minimal--line-number-at            "code-review-minimal")
(declare-function code-review-minimal--clear-overlays            "code-review-minimal")
(declare-function code-review-minimal--insert-discussion-overlay "code-review-minimal")

;;;; ─── GitLab Remote Parsing ─────────────────────────────────────────────────

(defun code-review-minimal--parse-gitlab-project-path (remote-url)
  "Extract namespace/project from REMOTE-URL (ssh or https)."
  (when remote-url
    (cond
     ;; SSH: git@host:namespace/project.git
     ((string-match "git@[^:]+:\\(.*\\)\\.git$" remote-url)
      (match-string 1 remote-url))
     ;; HTTPS: https://host/namespace/project.git
     ((string-match "https?://[^/]+/\\(.*\\)\\.git$" remote-url)
      (match-string 1 remote-url))
     ;; HTTPS without .git suffix
     ((string-match "https?://[^/]+/\\(.*[^/]\\)/*$" remote-url)
      (match-string 1 remote-url)))))

;;;; ─── GitLab HTTP Layer ──────────────────────────────────────────────────────

(defun code-review-minimal--gitlab-api-url (&rest path-segments)
  "Build a full GitLab API URL by joining PATH-SEGMENTS onto the base URL."
  (concat code-review-minimal-gitlab-base-url
          "/" (mapconcat #'identity path-segments "/")))

(defun code-review-minimal--gitlab-http-request (method url &optional payload callback)
  "Perform async HTTP METHOD request to GitLab URL via ghub.
PAYLOAD is an alist sent as JSON body.  CALLBACK receives parsed JSON."
  (code-review-minimal--assert-token 'gitlab)
  (let* ((token    (code-review-minimal--get-token 'gitlab))
         (host     (replace-regexp-in-string "^https?://" ""
                                             code-review-minimal-gitlab-base-url))
         (resource (substring url (length code-review-minimal-gitlab-base-url)))
         (wrapped-callback
          (when callback
            (lambda (result _headers _status _req)
              (funcall callback result)))))
    (ghub-request method resource nil
                  :auth      token
                  :host      host
                  :forge     'gitlab
                  :payload   payload
                  :callback  wrapped-callback
                  :errorback
                  (lambda (err _headers _status _req)
                    (message "code-review-minimal[gitlab]: HTTP error for %s: %S" url err)))))

;;;; ─── GitLab Backend Functions ──────────────────────────────────────────────

(defun code-review-minimal--gitlab-ensure-project-id ()
  "Set project ID from remote for GitLab backend."
  (unless (alist-get 'project-id code-review-minimal--project-info)
    (let* ((remote (code-review-minimal--git-remote-url))
           (path   (code-review-minimal--parse-gitlab-project-path remote)))
      (if path
          (progn
            (message "code-review-minimal: detected project %s" path)
            (setq code-review-minimal--project-info
                  `((project-id . ,(url-hexify-string path)))))
        (let ((manual (read-string "Project path (e.g. team/project): ")))
          (setq code-review-minimal--project-info
                `((project-id . ,(url-hexify-string manual))))))))
  (alist-get 'project-id code-review-minimal--project-info))

(defun code-review-minimal--gitlab-resolve-mr-id (callback)
  "Resolve MR global id for the current IID and call CALLBACK with it."
  (if code-review-minimal--mr-id
      (funcall callback code-review-minimal--mr-id)
    (let* ((project-id (code-review-minimal--gitlab-ensure-project-id))
           (url        (code-review-minimal--gitlab-api-url
                        "projects" project-id "merge_request" "iid"
                        (number-to-string code-review-minimal--mr-iid)))
           (buf        (current-buffer)))
      (message "code-review-minimal: resolving MR id for IID %d ..." code-review-minimal--mr-iid)
      (code-review-minimal--gitlab-http-request
       "GET" url nil
       (lambda (mr)
         (let ((mr-id (and mr (alist-get 'id mr))))
           (if (not (numberp mr-id))
               (message "code-review-minimal: failed to resolve MR id")
             (with-current-buffer buf
               (setq code-review-minimal--mr-id mr-id))
             (funcall callback mr-id))))))))

(defun code-review-minimal--gitlab-fetch-comments ()
  "Fetch MR comments and render overlays (GitLab)."
  (let* ((project-id (code-review-minimal--gitlab-ensure-project-id))
         (mr-iid     code-review-minimal--mr-iid)
         (rel-path   (code-review-minimal--relative-file-path))
         (buf        (current-buffer)))
    (message "code-review-minimal: fetching comments for MR !%d ..." mr-iid)
    (code-review-minimal--gitlab-resolve-mr-id
     (lambda (mr-id)
       (let ((url (concat
                   (code-review-minimal--gitlab-api-url
                    "projects" project-id "merge_requests"
                    (number-to-string mr-id) "notes")
                   "?per_page=100")))
         (code-review-minimal--gitlab-http-request
          "GET" url nil
          (lambda (notes)
            (with-current-buffer buf
              (code-review-minimal--clear-overlays)
              (if (null notes)
                  (message "code-review-minimal: no comments found")
                (code-review-minimal--gitlab-process-notes notes rel-path))))))))))

(defun code-review-minimal--gitlab-process-notes (notes rel-path)
  "Process GitLab NOTES and create overlays for REL-PATH."
  (let* ((total    (length notes))
         (count    0)
         (by-id    (make-hash-table))
         (children (make-hash-table))
         (roots    nil))
    (dolist (n notes)
      (let ((id  (alist-get 'id        n))
            (pid (alist-get 'parent_id n)))
        (puthash id n by-id)
        (if pid
            (puthash pid (append (gethash pid children) (list n)) children)
          (push n roots))))
    (setq roots (nreverse roots))
    (dolist (root roots)
      (let* ((file-path    (alist-get 'file_path root))
             (note-pos     (alist-get 'note_position root))
             (latest-pos   (and note-pos (alist-get 'latest_position note-pos)))
             (line-num     (and latest-pos
                                (or (alist-get 'right_line_num latest-pos)
                                    (alist-get 'left_line_num  latest-pos))))
             (resolve-state (alist-get 'resolve_state root))
             (resolved     (cond ((eql resolve-state 2) t)
                                 ((eql resolve-state 1) :json-false)
                                 (t nil)))
             (root-id      (alist-get 'id root))
             (thread       (cons root (gethash root-id children))))
        (when (and (integerp line-num)
                   file-path
                   rel-path
                   (string= file-path rel-path))
          (code-review-minimal--insert-discussion-overlay line-num thread resolved root-id)
          (cl-incf count))))
    (message "code-review-minimal: %d thread(s) in this file, %d total notes." count total)))

(defun code-review-minimal--gitlab-post-comment (_beg end body)
  "Post comment on line at END with BODY (GitLab)."
  (let* ((project-id (code-review-minimal--gitlab-ensure-project-id))
         (rel-path   (code-review-minimal--relative-file-path))
         (end-line   (code-review-minimal--line-number-at end))
         (src-buf    (current-buffer)))
    (code-review-minimal--gitlab-resolve-mr-id
     (lambda (mr-id)
       (let* ((url     (code-review-minimal--gitlab-api-url
                        "projects" project-id "merge_requests"
                        (number-to-string mr-id) "notes"))
              (payload `((body      . ,body)
                         (path      . ,rel-path)
                         (line      . ,(number-to-string end-line))
                         (line_type . "new"))))
         (code-review-minimal--gitlab-http-request
          "POST" url payload
          (lambda (resp)
            (if (and resp (alist-get 'id resp))
                (progn
                  (message "code-review-minimal: comment posted (id=%s)" (alist-get 'id resp))
                  (with-current-buffer src-buf
                    (code-review-minimal--gitlab-fetch-comments)))
              (message "code-review-minimal: failed to post comment")))))))))

(defun code-review-minimal--gitlab-update-comment (note-id body)
  "Update NOTE-ID with BODY (GitLab)."
  (let* ((project-id (code-review-minimal--gitlab-ensure-project-id))
         (src-buf    (current-buffer)))
    (code-review-minimal--gitlab-resolve-mr-id
     (lambda (mr-id)
       (let* ((url     (code-review-minimal--gitlab-api-url
                        "projects" project-id "merge_requests"
                        (number-to-string mr-id) "notes" (number-to-string note-id)))
              (payload `((body . ,body))))
         (code-review-minimal--gitlab-http-request
          "PUT" url payload
          (lambda (resp)
            (if (and resp (alist-get 'id resp))
                (progn
                  (message "code-review-minimal: note %d updated" note-id)
                  (with-current-buffer src-buf
                    (code-review-minimal--gitlab-fetch-comments)))
              (message "code-review-minimal: failed to update note %d" note-id)))))))))

(defun code-review-minimal--gitlab-resolve-comment (ov)
  "Resolve comment at overlay OV (GitLab)."
  (let ((note-id    (overlay-get ov 'code-review-minimal-note-id))
        (note-body  (overlay-get ov 'code-review-minimal-body))
        (project-id (code-review-minimal--gitlab-ensure-project-id))
        (src-buf    (current-buffer)))
    (code-review-minimal--gitlab-resolve-mr-id
     (lambda (mr-id)
       (let ((url (code-review-minimal--gitlab-api-url
                   "projects" project-id "merge_requests"
                   (number-to-string mr-id) "notes" (number-to-string note-id))))
         (code-review-minimal--gitlab-http-request
          "PUT" url
          `((body . ,note-body) (resolve_state . 2))
          (lambda (resp)
            (if (and resp (alist-get 'id resp))
                (progn
                  (message "code-review-minimal: note %d resolved" note-id)
                  (with-current-buffer src-buf
                    (code-review-minimal--gitlab-fetch-comments)))
              (message "code-review-minimal: failed to resolve note %d" note-id)))))))))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-gitlab)

;;; code-review-minimal-gitlab.el ends here
