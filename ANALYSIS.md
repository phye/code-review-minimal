# Code-Review-Minimal Repository Analysis

## Overview
This is an Emacs minor mode package for performing code reviews directly inside Emacs against GitHub Pull Requests, GitLab Merge Requests, and Gongfeng (Tencent GitLab) MRs.

**Project Status**: WIP (Work in Progress)
**Version**: 0.2.0
**License**: MIT
**Author**: phye

---

## 1. FILES STRUCTURE

### Main Files
```
├── code-review-minimal.el      (Main package - 1125 lines, ~52KB)
├── README.md                   (Documentation)
└── .gitignore                  (Empty)
```

### Key Statistics
- **Single main file**: `code-review-minimal.el` (1125 lines)
- **Package Requirements**: Emacs 27.1+
- **External Dependencies**: Only built-in Emacs libraries (json, url, url-http, cl-lib, subr-x)

---

## 2. SUPPORTED BACKENDS & API ENDPOINTS

### Backend Detection (Lines 169-184)
Automatically detects backend from git remote URL with priority order:
1. **Gongfeng** (git.woa.com)
2. **GitHub** (github.com or contains "github")
3. **GitLab** (contains "gitlab")

### Backend-Specific Details

#### GitHub
- **Domain**: github.com or GitHub Enterprise
- **API Base URL**: `https://api.github.com` (customizable)
- **API Version**: REST API v3
- **Authentication**: Bearer token (Authorization header)
- **Configuration Variables** (Lines 66-91):
  - `code-review-minimal-github-token`
  - `code-review-minimal-github-base-url`

#### GitLab
- **Domain**: gitlab.com or self-hosted
- **API Base URL**: `https://gitlab.com/api/v4` (customizable)
- **API Version**: API v4
- **Authentication**: PRIVATE-TOKEN header
- **Configuration Variables** (Lines 73-98):
  - `code-review-minimal-gitlab-token`
  - `code-review-minimal-gitlab-base-url`

#### Gongfeng (Tencent GitLab)
- **Domain**: git.woa.com
- **API Base URL**: `https://git.woa.com/api/v3` (customizable)
- **API Version**: API v3 (note: v3, not v4)
- **Authentication**: PRIVATE-TOKEN header
- **Configuration Variables** (Lines 80-102):
  - `code-review-minimal-gongfeng-token`
  - `code-review-minimal-gongfeng-base-url`
  - `code-review-minimal-private-token` (deprecated)
  - `code-review-minimal-base-url` (deprecated)

---

## 3. AUTHENTICATION & HTTP HANDLING

### Token Management

#### Token Storage (Lines 274-306)
Function: `code-review-minimal--get-token` (Line 274)
- Returns appropriate token based on backend
- Validates token is not empty before use

Function: `code-review-minimal-set-token` (Line 283)
- Interactive command to set token for backend
- Supports: github, gitlab, gongfeng
- Uses: `code-review-minimal-set-token` (interactive)

#### Token Assertion (Line 302)
Function: `code-review-minimal--assert-token`
- Ensures token is configured and non-empty
- Signals error if missing with helpful message

### Authentication Headers (Lines 386-399)
Function: `code-review-minimal--make-auth-headers`

**GitHub Headers**:
```
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
```

**GitLab/Gongfeng Headers**:
```
PRIVATE-TOKEN: <token>
Content-Type: application/json; charset=utf-8
```

### HTTP Request Mechanism (Lines 401-427)
Function: `code-review-minimal--http-request`

**Method Signature**:
```elisp
(code-review-minimal--http-request backend method url &optional payload callback)
```

**Parameters**:
- `backend`: github, gitlab, or gongfeng
- `method`: HTTP verb (GET, POST, PUT, PATCH)
- `url`: Full API URL
- `payload`: Optional JSON body (auto-encoded to UTF-8)
- `callback`: Function to call with parsed response

**Implementation Details**:
- Uses `url-retrieve` (async Emacs builtin)
- Sets `url-request-method`, `url-request-extra-headers`, `url-request-data`
- Parses HTTP status code (Lines 429-434)
- Extracts response body (Lines 436-442)
- Parses JSON response (Lines 444-454)
- Error handling for HTTP 400+ status codes
- Async callback pattern

### Response Parsing (Lines 429-454)
- `code-review-minimal--http-status-code`: Extracts status from HTTP headers
- `code-review-minimal--response-body`: Extracts body after empty line separator
- `code-review-minimal--parse-response`: JSON parsing with error handling

---

## 4. API ENDPOINT MAPPING

### API URL Construction (Lines 377-384)
Function: `code-review-minimal--api-url`
- Builds URLs by joining backend base URL with path segments
- Example: `https://api.github.com` + "repos" + "owner" + "repo" + "pulls" → `https://api.github.com/repos/owner/repo/pulls`

### GitHub API Endpoints

| Operation | Endpoint | Method | Line |
|-----------|----------|--------|------|
| Fetch PR Comments | `/repos/{owner}/{repo}/pulls/{pr_number}/comments` | GET | 696 |
| Get PR Details (for head SHA) | `/repos/{owner}/{repo}/pulls/{pr_number}` | GET | 737 |
| Post Review Comment | `/repos/{owner}/{repo}/pulls/{pr_number}/comments` | POST | 748, 756 |
| Update Comment | `/repos/{owner}/{repo}/pulls/comments/{note_id}` | PATCH | 775 |

**GitHub-Specific Logic** (Line 742):
- Requires commit SHA (`head_sha`) from PR head for posting comments
- Two-step process: 1) fetch PR data, 2) post comment with commit SHA

### GitLab/Gongfeng API Endpoints

| Operation | Endpoint | Method | Line |
|-----------|----------|--------|------|
| Resolve MR ID from IID | `/projects/{project_id}/merge_request/iid/{iid}` | GET | 506-508 |
| Fetch MR Notes (comments) | `/projects/{project_id}/merge_requests/{mr_id}/notes?per_page=100` | GET | 534-538 |
| Post Comment | `/projects/{project_id}/merge_requests/{mr_id}/notes` | POST | 600-603, 608-610 |
| Update Comment | `/projects/{project_id}/merge_requests/{mr_id}/notes/{note_id}` | PUT | 625-628, 630-632 |
| Resolve Comment | `/projects/{project_id}/merge_requests/{mr_id}/notes/{note_id}` | PUT | 649-652, 653-655 |

**GitLab/Gongfeng-Specific Logic**:
- Uses `project-id` (URL-hexified namespace/project) not project number
- Resolves MR "IID" (project-relative ID) to global `mr-id`
- Comment resolver state: `resolve_state` payload (0=open, 1=unresolved, 2=resolved)
- Supports `file_path` and `line_type` ("new"/"old") for positioning
- Thread structure: root notes + child replies via `parent_id`

---

## 5. HTTP REQUEST FLOW - DETAILED EXAMPLES

### Example 1: Fetch GitHub PR Comments

```elisp
;; Line 684-703: code-review-minimal--github-fetch-comments
(let ((url "https://api.github.com/repos/owner/repo/pulls/123/comments"))
  (code-review-minimal--http-request
   'github
   "GET" url nil
   (lambda (comments)
     ;; Process comments list
     (code-review-minimal--github-process-comments comments rel-path))))
```

**Request**:
```
GET /repos/owner/repo/pulls/123/comments HTTP/1.1
Host: api.github.com
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
```

### Example 2: Post GitHub PR Review Comment (Two-Step)

**Step 1** (Line 735-741): Get PR head commit SHA
```elisp
(let ((pr-url "https://api.github.com/repos/owner/repo/pulls/123"))
  (code-review-minimal--http-request 'github "GET" pr-url nil
    (lambda (pr-data)
      (let ((head-sha (alist-get 'sha (alist-get 'head pr-data)))))))
```

**Step 2** (Line 746-756): Post comment with commit SHA
```elisp
(let ((url "https://api.github.com/repos/owner/repo/pulls/123/comments")
      (payload '((body . "Review comment")
                 (path . "src/file.js")
                 (line . 42)
                 (side . "RIGHT")
                 (commit_id . "abc123def"))))
  (code-review-minimal--http-request 'github "POST" url payload
    (lambda (resp) ...)))
```

**Request**:
```
POST /repos/owner/repo/pulls/123/comments HTTP/1.1
Host: api.github.com
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28

{"body":"Review comment","path":"src/file.js","line":42,"side":"RIGHT","commit_id":"abc123def"}
```

### Example 3: Fetch GitLab/Gongfeng MR Comments

**Step 1** (Line 506-521): Resolve MR IID to ID
```elisp
(let ((url "https://git.woa.com/api/v3/projects/namespace%2Fproject/merge_request/iid/42"))
  (code-review-minimal--http-request 'gongfeng "GET" url nil
    (lambda (mr) (setq code-review-minimal--mr-id (alist-get 'id mr)))))
```

**Step 2** (Line 534-548): Fetch comments
```elisp
(let ((url "https://git.woa.com/api/v3/projects/namespace%2Fproject/merge_requests/999/notes?per_page=100"))
  (code-review-minimal--http-request 'gongfeng "GET" url nil
    (lambda (notes) (code-review-minimal--gitlab-process-notes notes rel-path))))
```

**Request**:
```
GET /api/v3/projects/namespace%2Fproject/merge_requests/999/notes?per_page=100 HTTP/1.1
Host: git.woa.com
PRIVATE-TOKEN: <token>
Content-Type: application/json; charset=utf-8
```

### Example 4: Post GitLab/Gongfeng Comment

```elisp
(let ((url "https://git.woa.com/api/v3/projects/namespace%2Fproject/merge_requests/999/notes")
      (payload '((body . "Code review comment")
                 (path . "src/file.js")
                 (line . "42")
                 (line_type . "new"))))
  (code-review-minimal--http-request 'gongfeng "POST" url payload
    (lambda (resp) ...)))
```

**Request**:
```
POST /api/v3/projects/namespace%2Fproject/merge_requests/999/notes HTTP/1.1
Host: git.woa.com
PRIVATE-TOKEN: <token>
Content-Type: application/json; charset=utf-8

{"body":"Code review comment","path":"src/file.js","line":"42","line_type":"new"}
```

### Example 5: Resolve GitLab/Gongfeng Comment

```elisp
(let ((url "https://git.woa.com/api/v3/projects/namespace%2Fproject/merge_requests/999/notes/555")
      (payload '((body . "Original comment")
                 (resolve_state . 2))))
  (code-review-minimal--http-request 'gongfeng "PUT" url payload
    (lambda (resp) ...)))
```

---

## 6. AUTHENTICATION CONFIGURATION

### Setup Per Backend

#### GitHub
```elisp
(setq code-review-minimal-github-token "ghp_xxxxxxxxxxxx")
;; Optional:
(setq code-review-minimal-github-base-url "https://github.com/api/v3") ;; Enterprise
```

#### GitLab
```elisp
(setq code-review-minimal-gitlab-token "glpat-xxxxxxxxxxxx")
;; Optional:
(setq code-review-minimal-gitlab-base-url "https://gitlab.company.com/api/v4")
```

#### Gongfeng
```elisp
(setq code-review-minimal-gongfeng-token "xxxxxxxxxxxx")
;; Optional:
(setq code-review-minimal-gongfeng-base-url "https://git.woa.com/api/v3")
```

### Token Setup Commands
- `M-x code-review-minimal-set-token` (Line 283): Interactive setup
- `M-x code-review-minimal-set-gongfeng-token` (Line 297): Legacy alias

---

## 7. REMOTE URL PARSING

### Functions (Lines 308-351)

**`code-review-minimal--git-remote-url`** (Line 310):
- Calls `git remote get-url origin`
- Returns origin remote URL

**`code-review-minimal--parse-gitlab-project-path`** (Line 318):
- Extracts `namespace/project` from SSH or HTTPS URLs
- URL-hexifies result (spaces → %20, slashes → %2F)
- Example: `namespace/sub/project` → `namespace%2Fsub%2Fproject`

**`code-review-minimal--parse-github-repo`** (Line 333):
- Extracts `(owner . repo)` tuple from git remote
- Handles SSH, HTTPS, GitHub Enterprise, with/without `.git` suffix
- Returns: `(cons owner repo)`

### Supported Remote Formats

**SSH**:
- `git@github.com:owner/repo.git`
- `git@github.com:owner/repo`
- `git@git.woa.com:namespace/project.git`

**HTTPS**:
- `https://github.com/owner/repo.git`
- `https://github.com/owner/repo`
- `https://gitlab.com/namespace/project.git`
- `https://git.woa.com/namespace/project`

---

## 8. DEPENDENCIES

### Package-Requires Header (Line 6)
```elisp
;; Package-Requires: ((emacs "27.1"))
```

### Built-in Emacs Libraries (Lines 42-46)
- `json` - JSON encoding/decoding
- `url` - HTTP client
- `url-http` - HTTP-specific URL handling
- `cl-lib` - Common Lisp library
- `subr-x` - Extra subroutine utilities

**No external package dependencies** - all core Emacs functionality

---

## 9. CACHING MECHANISM

### Per-Repository Cache (Lines 186-245)

**In-Memory Cache** (Lines 188-192):
```elisp
code-review-minimal--iid-cache          ; Maps git-root → MR IID
code-review-minimal--backend-cache      ; Maps git-root → backend symbol
```

**Disk Persistence** (Lines 200-245):
- Location: `.git/code-review-minimal-iid` (stores MR/PR IID)
- Location: `.git/code-review-minimal-backend` (stores backend choice)

**Functions**:
- `code-review-minimal--load-cached-iid` (Line 204)
- `code-review-minimal--save-iid` (Line 219)
- `code-review-minimal--load-cached-backend` (Line 226)
- `code-review-minimal--save-backend` (Line 240)

---

## 10. CODE FLOW FOR KEY OPERATIONS

### Enable Code Review Mode (Lines 1071-1118)

```
code-review-minimal-mode toggle
  ├─ code-review-minimal--ensure-backend
  │  ├─ Load cached backend from .git/code-review-minimal-backend
  │  ├─ Or detect from git remote URL
  │  └─ Save backend choice
  ├─ code-review-minimal--assert-token (ensure auth configured)
  ├─ Load cached MR IID or prompt user
  └─ code-review-minimal--fetch-comments
     ├─ GitHub: code-review-minimal--github-fetch-comments
     │  └─ GET /repos/{owner}/{repo}/pulls/{pr}/comments
     └─ GitLab/Gongfeng: code-review-minimal--gitlab-fetch-comments
        ├─ GET /projects/{id}/merge_request/iid/{iid}
        └─ GET /projects/{id}/merge_requests/{mr_id}/notes
```

### Add Comment (Lines 1014-1022)

```
code-review-minimal-add-comment (region selected)
  ├─ Validate mode enabled & MR IID set
  ├─ code-review-minimal--open-input-overlay (show input buffer)
  └─ User types C-c C-c to submit
     └─ code-review-minimal--submit-comment
        ├─ code-review-minimal--post-comment
        │  ├─ GitHub: code-review-minimal--github-post-comment
        │  │  ├─ GET PR head SHA
        │  │  └─ POST /repos/{owner}/{repo}/pulls/{pr}/comments
        │  └─ GitLab/Gongfeng: code-review-minimal--gitlab-post-comment
        │     └─ POST /projects/{id}/merge_requests/{mr_id}/notes
        └─ code-review-minimal--gitlab-fetch-comments (refresh display)
```

### Resolve Comment (Lines 1050-1062)

```
code-review-minimal-resolve-comment (at overlay point)
  ├─ Find overlay at current line
  ├─ code-review-minimal--resolve-comment
  │  ├─ GitHub: code-review-minimal--github-resolve-comment
  │  │  └─ Message: "GitHub resolution via web UI"
  │  └─ GitLab/Gongfeng: code-review-minimal--gitlab-resolve-comment
  │     └─ PUT /projects/{id}/merge_requests/{mr_id}/notes/{id}
  │        └─ Payload: (resolve_state . 2)
  └─ Refresh comments display
```

---

## 11. DATA STRUCTURES

### Buffer-Local State (Lines 248-270)

```elisp
code-review-minimal--mr-iid          ; MR IID (project-relative number)
code-review-minimal--mr-id           ; MR global ID (resolved)
code-review-minimal--project-info    ; Backend-specific project data
  ; GitHub: ((owner . "org") (repo . "name"))
  ; GitLab/Gongfeng: ((project-id . "namespace%2Fproject"))
code-review-minimal--current-backend ; 'github, 'gitlab, or 'gongfeng
code-review-minimal--overlays        ; List of comment overlays
code-review-minimal--input-overlay   ; Active input overlay or nil
```

### Comment/Note Structure (from API responses)

**GitHub Comment (API v3)**:
```json
{
  "id": 12345,
  "body": "Review comment",
  "path": "src/file.js",
  "line": 42,
  "created_at": "2024-01-01T12:00:00Z",
  "user": {"login": "username"}
}
```

**GitLab/Gongfeng Note (API v3/v4)**:
```json
{
  "id": 999,
  "body": "Review comment",
  "file_path": "src/file.js",
  "created_at": "2024-01-01T12:00:00Z",
  "author": {"name": "User Name"},
  "note_position": {
    "latest_position": {
      "right_line_num": 42,
      "left_line_num": 40
    }
  },
  "parent_id": null,
  "resolve_state": 0,  # 0=open, 1=unresolved, 2=resolved
  "notes": [...] # replies
}
```

---

## 12. ERROR HANDLING & DEBUGGING

### HTTP Error Handling (Lines 413-426)
- Checks for `:error` in status plist
- Checks for HTTP 400+ status codes
- Logs errors to `*Messages*` buffer
- Graceful degradation (shows truncated 400-char response)

### Message Logging
All operations log to `*Messages*` buffer:
- "code-review-minimal: using %s backend"
- "code-review-minimal: auto-detected %s backend"
- "code-review-minimal: failed to resolve MR id"
- "code-review-minimal: %d thread(s) in this file"
- etc.

---

## 13. OVERLAY RENDERING & DISPLAY

### Comment Display (Lines 795-848)
- Renders notes with author, timestamp, status (resolved/open)
- Visual indicators: ✓ for resolved, ○ for open
- Thread visualization with separator lines
- Face customization per state (resolved vs. unresolved)

### Input Overlay (Lines 852-952)
- Transient mode (`code-review-minimal-input-mode`)
- Keymap: C-c C-c (submit), C-c C-k (cancel)
- Stores reference to source buffer and region

---

## 14. ARCHITECTURAL SUMMARY

```
┌─ Backend Detection Layer
│  ├─ Git remote URL parsing
│  └─ Auto-detect or manual override
│
├─ Authentication Layer
│  ├─ Per-backend token storage
│  ├─ Header construction (Authorization/PRIVATE-TOKEN)
│  └─ Token validation
│
├─ HTTP Layer
│  ├─ URL building (path segment joining)
│  ├─ Async request dispatch (url-retrieve)
│  ├─ Response parsing (JSON)
│  └─ Error handling
│
├─ API Integration Layer
│  ├─ GitHub endpoints
│  ├─ GitLab/Gongfeng endpoints
│  └─ Backend dispatch functions
│
├─ Data Persistence Layer
│  ├─ In-memory caches (IID, backend)
│  └─ Git .git/ directory persistence
│
├─ UI Layer
│  ├─ Overlay rendering
│  ├─ Input mode
│  ├─ Faces/styling
│  └─ Interactive commands
│
└─ State Management Layer
   ├─ Buffer-local variables
   ├─ Mode toggle
   └─ Lifecycle hooks
```

---

## 15. KEY CODE SNIPPETS BY FUNCTIONALITY

### HTTP Request Core (Lines 401-427)
```elisp
(defun code-review-minimal--http-request (backend method url &optional payload callback)
  (code-review-minimal--assert-token backend)
  (let* ((url-request-method method)
         (url-request-extra-headers (code-review-minimal--make-auth-headers backend))
         (url-request-data
          (when payload
            (encode-coding-string (json-encode payload) 'utf-8))))
    (url-retrieve
     url
     (lambda (status)
       (let* ((http-status (code-review-minimal--http-status-code))
              (err (plist-get status :error))
              (resp-body (code-review-minimal--response-body)))
         (cond
          (err
           (message "code-review-minimal: HTTP error %S" err))
          ((and http-status (>= http-status 400))
           (message "code-review-minimal: HTTP %d" http-status))
          (t
           (let ((result (code-review-minimal--parse-response)))
             (when callback
               (funcall callback result)))))))
     nil t)))
```

### Backend Dispatch (Lines 956-982)
```elisp
(defun code-review-minimal--fetch-comments ()
  (pcase code-review-minimal--current-backend
    ('github (code-review-minimal--github-fetch-comments))
    ((or 'gitlab 'gongfeng) (code-review-minimal--gitlab-fetch-comments))
    (_ (error "Unknown backend: %s" code-review-minimal--current-backend))))
```

### Project Info Resolution
**GitHub** (Lines 667-682):
- Parse remote → extract owner/repo
- Store in `code-review-minimal--project-info` as alist

**GitLab/Gongfeng** (Lines 486-499):
- Parse remote → extract namespace/project
- URL-hexify namespace/project for API
- Store as `project-id` in alist

---

## 16. SECURITY CONSIDERATIONS

### Token Storage
- ⚠️ **In-memory**: Tokens stored in customizable variables (user-editable)
- ⚠️ **No encryption**: Tokens not encrypted on disk if persisted via `setq` in init file
- ✅ **Per-backend**: Can use environment variables or `.authinfo.gpg` (user responsible)
- ✅ **Never logged**: Tokens not printed to messages/logs

### API Security
- ✅ Uses HTTPS by default
- ✅ Sends tokens in request headers (not URL params)
- ✅ Content-Type set to JSON (not form-encoded)
- ✅ JSON encoding handles special characters

---

## SUMMARY TABLE

| Aspect | Details |
|--------|---------|
| **Main File** | `code-review-minimal.el` (1125 lines) |
| **Backends** | GitHub, GitLab, Gongfeng |
| **HTTP Library** | Emacs `url` + `url-http` |
| **Auth Method** | Bearer token (GitHub) / PRIVATE-TOKEN (GitLab/Gongfeng) |
| **Request Pattern** | Async callbacks via `url-retrieve` |
| **API Versions** | GitHub REST v3, GitLab v4, Gongfeng v3 |
| **Caching** | In-memory + `.git/` directory |
| **Dependencies** | Emacs 27.1+ only (built-in libs) |
| **Threading** | Comment threads with parent_id tracking |
| **Resolution** | GitLab/Gongfeng only (GitHub web-only) |

