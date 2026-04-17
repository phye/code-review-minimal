;;; code-review-minimal-gongfeng.el --- Gongfeng backend for code-review-minimal -*- lexical-binding: t; -*-

;; Author: phye
;; Keywords: tools, vc, review

;;; Commentary:
;;
;; Gongfeng backend for code-review-minimal.
;; Handles MR comment fetching, posting, updating, and resolving against
;; Gongfeng (工蜂), Tencent's code hosting platform, accessible at
;; git.woa.com (internal) and code.tencent.com (external).
;;
;; Authentication:
;;   Tokens are read exclusively from authinfo/netrc.  Add an entry to
;;   ~/.authinfo (or ~/.authinfo.gpg):
;;     machine git.woa.com      login ^crm password <token>
;;     machine code.tencent.com login ^crm password <token>
;;   The host is derived from `code-review-minimal-gongfeng-api-url'.
;;
;; HTTP layer: Emacs built-in `url-retrieve' with a PRIVATE-TOKEN request
;; header.  Gongfeng runs a customised GitLab REST API v3 that is NOT
;; wire-compatible with the GitLab API v4 used by the gitlab backend, so
;; ghub is deliberately avoided here.
;;
;; API endpoints used (base: https://git.woa.com/api/v3, configurable via
;; `code-review-minimal-gongfeng-api-url'):
;;   Resolve MR id : GET  /projects/:encoded_path/merge_request/iid/:iid → .id
;;   List notes    : GET  /projects/:encoded_path/merge_requests/:id/notes
;;   Create note   : POST /projects/:encoded_path/merge_requests/:id/notes
;;   Update note   : PUT  /projects/:encoded_path/merge_requests/:id/notes/:note_id
;;
;; Backend contract:
;;   :fetch  (callback)                — calls (callback THREADS)
;;   :post   (beg end body on-success) — calls (on-success) on success
;;   :update (note-id body on-success) — calls (on-success) on success
;;   :resolve (ov on-success)          — calls (on-success) on success

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'cl-lib)
(require 'subr-x)

;; Declare variables and functions from the parent package to avoid
;; circular-require warnings.  These are always present at runtime because
;; code-review-minimal.el loads this file.
(defvar code-review-minimal--project-info)
(defvar code-review-minimal--mr-iid)
(defvar code-review-minimal--mr-id)
(defvar code-review-minimal--current-backend)
(defvar code-review-minimal-gongfeng-api-url)
(declare-function code-review-minimal--git-remote-url "code-review-minimal")
(declare-function code-review-minimal--get-token "code-review-minimal")
(declare-function code-review-minimal--relative-file-path "code-review-minimal")
(declare-function code-review-minimal--line-number-at "code-review-minimal")

;;;; ─── Gongfeng Remote Parsing ────────────────────────────────────────────────

(defun code-review-minimal--parse-gongfeng-project-path (remote-url)
  "Extract namespace/project from REMOTE-URL (ssh or https)."
  (when remote-url
    (cond
     ;; SSH: git@git.woa.com:namespace/project.git
     ((string-match "git@[^:]+:\\(.*\\)\\.git$" remote-url)
      (match-string 1 remote-url))
     ;; HTTPS: https://git.woa.com/namespace/project.git
     ((string-match "https?://[^/]+/\\(.*\\)\\.git$" remote-url)
      (match-string 1 remote-url))
     ;; HTTPS without .git suffix
     ((string-match "https?://[^/]+/\\(.*[^/]\\)/*$" remote-url)
      (match-string 1 remote-url)))))

;;;; ─── Gongfeng HTTP Layer (url-retrieve, not ghub) ──────────────────────────

(defun code-review-minimal--gongfeng-api-url (&rest path-segments)
  "Build a full Gongfeng API URL by joining PATH-SEGMENTS onto the base URL."
  (concat code-review-minimal-gongfeng-api-url "/" (mapconcat #'identity path-segments "/")))

(defun code-review-minimal--gongfeng-http-status ()
  "Return the integer HTTP status from the current url-retrieve buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
      (string-to-number (match-string 1)))))

(defun code-review-minimal--gongfeng-response-body ()
  "Return the response body string from the current url-retrieve buffer."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^\\s-*$" nil t)
        (decode-coding-string (buffer-substring (point) (point-max)) 'utf-8)
      "")))

(defun code-review-minimal--gongfeng-parse-response ()
  "Parse JSON body from the current url-retrieve buffer."
  (let ((body (code-review-minimal--gongfeng-response-body)))
    (condition-case err
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'symbol))
          (json-read-from-string body))
      (error
       (message "code-review-minimal[gongfeng]: JSON parse error: %S\nbody: %s" err body)
       nil))))

(defun code-review-minimal--gongfeng-http-request (method url &optional payload callback)
  "Perform async HTTP METHOD request to Gongfeng URL via url-retrieve.
PAYLOAD is an alist JSON-encoded as the request body.
CALLBACK receives the parsed JSON response (or nil on error)."
  (let* ((token (encode-coding-string (or (code-review-minimal--get-token 'gongfeng) "") 'utf-8))
         (url-request-method method)
         (url-request-extra-headers
          `(("PRIVATE-TOKEN" . ,token) ("Content-Type" . "application/json; charset=utf-8")))
         (url-request-data
          (when payload
            (let* ((body (json-encode payload))
                   ;; encode-coding-string produces a unibyte UTF-8 string,
                   ;; which url-http-create-request requires (Emacs Bug#23750).
                   (encoded (encode-coding-string body 'utf-8)))
              encoded))))
    (url-retrieve
     url
     (lambda (status)
       (let* ((http-status (code-review-minimal--gongfeng-http-status))
              (err (plist-get status :error))
              (body (code-review-minimal--gongfeng-response-body)))
         (cond
          (err
           (message "code-review-minimal[gongfeng]: HTTP error %S (URL: %s)\n  body: %s"
                    err
                    url
                    (substring body 0 (min 400 (length body)))))
          ((and http-status (>= http-status 400))
           (message "code-review-minimal[gongfeng]: HTTP %d for %s\n  body: %s"
                    http-status
                    url
                    (substring body 0 (min 400 (length body)))))
          (t
           (when callback
             (funcall callback (code-review-minimal--gongfeng-parse-response)))))))
     nil t)))

;;;; ─── Gongfeng Backend Functions ────────────────────────────────────────────

(defun code-review-minimal--gongfeng-ensure-project-id ()
  "Set project ID from remote for Gongfeng backend."
  (unless (alist-get 'project-id code-review-minimal--project-info)
    (let* ((remote (code-review-minimal--git-remote-url))
           (path (code-review-minimal--parse-gongfeng-project-path remote)))
      (if path
          (progn
            (message "code-review-minimal: detected project %s" path)
            (setq code-review-minimal--project-info `((project-id . ,(url-hexify-string path)))))
        (let ((manual (read-string "Project path (e.g. team/project): ")))
          (setq code-review-minimal--project-info `((project-id . ,(url-hexify-string manual))))))))
  (alist-get 'project-id code-review-minimal--project-info))

(defun code-review-minimal--gongfeng-resolve-mr-id (callback)
  "Resolve MR global id for the current IID and call CALLBACK with it."
  (if code-review-minimal--mr-id
      (funcall callback code-review-minimal--mr-id)
    (let* ((project-id (code-review-minimal--gongfeng-ensure-project-id))
           (url
            (code-review-minimal--gongfeng-api-url
             "projects"
             project-id
             "merge_request"
             "iid"
             (number-to-string code-review-minimal--mr-iid)))
           (buf (current-buffer)))
      (message "code-review-minimal: resolving MR id for IID %d ..." code-review-minimal--mr-iid)
      (code-review-minimal--gongfeng-http-request
       "GET" url
       nil
       (lambda (mr)
         (let ((mr-id (and mr (alist-get 'id mr))))
           (if (not (numberp mr-id))
               (message "code-review-minimal: failed to resolve Gongfeng MR id (response: %S)" mr)
             (with-current-buffer buf
               (setq code-review-minimal--mr-id mr-id))
             (funcall callback mr-id))))))))

(defun code-review-minimal--gongfeng-fetch-comments (callback)
  "Fetch MR notes and call CALLBACK with a list of thread plists (Gongfeng)."
  (let* ((project-id (code-review-minimal--gongfeng-ensure-project-id))
         (mr-iid code-review-minimal--mr-iid))
    (message "code-review-minimal: fetching comments for MR !%d ..." mr-iid)
    (code-review-minimal--gongfeng-resolve-mr-id
     (lambda (mr-id)
       (let ((url
              (concat
               (code-review-minimal--gongfeng-api-url
                "projects" project-id "merge_requests" (number-to-string mr-id) "notes")
               "?per_page=100")))
         (code-review-minimal--gongfeng-http-request
          "GET" url
          nil
          (lambda (notes)
            (funcall callback (code-review-minimal--gongfeng-normalize-notes notes)))))))))

(defun code-review-minimal--gongfeng-normalize-notes (notes)
  "Convert Gongfeng NOTES list into the standard thread plist format."
  (let ((by-id (make-hash-table))
        (children (make-hash-table))
        (roots nil)
        (result nil))
    (dolist (n (or notes '()))
      (let ((id (alist-get 'id n))
            (pid (alist-get 'parent_id n)))
        (puthash id n by-id)
        (if pid
            (puthash pid (append (gethash pid children) (list n)) children)
          (push n roots))))
    (dolist (root (nreverse roots))
      (let* ((file-path (alist-get 'file_path root))
             (note-pos (alist-get 'note_position root))
             (latest-pos (and note-pos (alist-get 'latest_position note-pos)))
             (line-num
              (and latest-pos
                   (or (alist-get 'right_line_num latest-pos)
                       (alist-get 'left_line_num latest-pos))))
             (resolve-state (alist-get 'resolve_state root))
             (resolved
              (cond
               ((eql resolve-state 2)
                t)
               ((eql resolve-state 1)
                :json-false)
               (t
                nil)))
             (root-id (alist-get 'id root))
             (thread (cons root (gethash root-id children))))
        (when (and (integerp line-num) file-path)
          (push (list
                 :path file-path
                 :line line-num
                 :thread thread
                 :resolved resolved
                 :note-id root-id)
                result))))
    (nreverse result)))

(defun code-review-minimal--gongfeng-post-comment (_beg end body on-success)
  "Post comment on line at END with BODY (Gongfeng), then call ON-SUCCESS."
  (let* ((project-id (code-review-minimal--gongfeng-ensure-project-id))
         (rel-path (code-review-minimal--relative-file-path))
         (end-line (code-review-minimal--line-number-at end)))
    (code-review-minimal--gongfeng-resolve-mr-id
     (lambda (mr-id)
       (let* ((url
               (code-review-minimal--gongfeng-api-url
                "projects" project-id "merge_requests" (number-to-string mr-id) "notes"))
              (payload
               `((body . ,body)
                 (path . ,rel-path)
                 (line . ,(number-to-string end-line))
                 (line_type . "new"))))
         (code-review-minimal--gongfeng-http-request
          "POST" url
          payload
          (lambda (resp)
            (if (and resp (alist-get 'id resp))
                (progn
                  (message "code-review-minimal: comment posted (id=%s)" (alist-get 'id resp))
                  (funcall on-success))
              (message "code-review-minimal: failed to post comment")))))))))

(defun code-review-minimal--gongfeng-update-comment (note-id body on-success)
  "Update NOTE-ID with BODY (Gongfeng), then call ON-SUCCESS."
  (let* ((project-id (code-review-minimal--gongfeng-ensure-project-id)))
    (code-review-minimal--gongfeng-resolve-mr-id
     (lambda (mr-id)
       (let* ((url
               (code-review-minimal--gongfeng-api-url
                "projects"
                project-id
                "merge_requests"
                (number-to-string mr-id)
                "notes"
                (number-to-string note-id)))
              (payload `((body . ,body))))
         (code-review-minimal--gongfeng-http-request
          "PUT" url
          payload
          (lambda (resp)
            (if (and resp (alist-get 'id resp))
                (progn
                  (message "code-review-minimal: note %d updated" note-id)
                  (funcall on-success))
              (message "code-review-minimal: failed to update note %d" note-id)))))))))

(defun code-review-minimal--gongfeng-resolve-comment (note-id note-body on-success)
  "Resolve comment NOTE-ID with NOTE-BODY (Gongfeng), then call ON-SUCCESS."
  (let ((project-id (code-review-minimal--gongfeng-ensure-project-id)))
    (code-review-minimal--gongfeng-resolve-mr-id
     (lambda (mr-id)
       (let ((url
              (code-review-minimal--gongfeng-api-url
               "projects"
               project-id
               "merge_requests"
               (number-to-string mr-id)
               "notes"
               (number-to-string note-id))))
         (code-review-minimal--gongfeng-http-request
          "PUT" url
          `((body . ,note-body) (resolve_state . 2))
          (lambda (resp)
            (if (and resp (alist-get 'id resp))
                (progn
                  (message "code-review-minimal: note %d resolved" note-id)
                  (funcall on-success))
              (message "code-review-minimal: failed to resolve note %d" note-id)))))))))

(defun code-review-minimal--gongfeng-reply-comment (note-id body on-success)
  "Post a reply to the thread rooted at NOTE-ID with BODY (Gongfeng), then call ON-SUCCESS."
  (let ((project-id (code-review-minimal--gongfeng-ensure-project-id)))
    (code-review-minimal--gongfeng-resolve-mr-id
     (lambda (mr-id)
       (let* ((url     (code-review-minimal--gongfeng-api-url
                        "projects" project-id "merge_requests"
                        (number-to-string mr-id) "notes"))
              (payload `((body      . ,body)
                         (parent_id . ,note-id))))
         (code-review-minimal--gongfeng-http-request
          "POST" url payload
          (lambda (resp)
            (if (and resp (alist-get 'id resp))
                (progn
                  (message "code-review-minimal: reply posted (id=%s)" (alist-get 'id resp))
                  (funcall on-success))
              (message "code-review-minimal: failed to post reply")))))))))

(defun code-review-minimal--gongfeng-delete-comment (note-id on-success)
  "Delete note NOTE-ID (Gongfeng), then call ON-SUCCESS."
  (let ((project-id (code-review-minimal--gongfeng-ensure-project-id)))
    (code-review-minimal--gongfeng-resolve-mr-id
     (lambda (mr-id)
       (let ((url (code-review-minimal--gongfeng-api-url
                   "projects" project-id "merge_requests"
                   (number-to-string mr-id) "notes" (number-to-string note-id))))
         (code-review-minimal--gongfeng-http-request
          "DELETE" url nil
          (lambda (_resp)
            (message "code-review-minimal: note %d deleted" note-id)
            (funcall on-success))))))))

;;;; ─── Provide ────────────────────────────────────────────────────────────────

(provide 'code-review-minimal-gongfeng)

;;; code-review-minimal-gongfeng.el ends here
