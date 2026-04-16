# HTTP/Network Code - Quick Reference

## Core HTTP Functions

### 1. HTTP Request Entry Point
- **Function**: `code-review-minimal--http-request`
- **Line**: 401-427
- **Purpose**: Core async HTTP request dispatcher
- **Key Code**:
```elisp
(url-retrieve url (lambda (status) ...) nil t)
```

### 2. Authentication Header Construction
- **Function**: `code-review-minimal--make-auth-headers`
- **Line**: 386-399
- **GitHub Auth** (Line 391-395):
  - Header: `Authorization: Bearer <token>`
  - Header: `Accept: application/vnd.github+json`
  - Header: `X-GitHub-Api-Version: 2022-11-28`

- **GitLab/Gongfeng Auth** (Line 397-399):
  - Header: `PRIVATE-TOKEN: <token>`

### 3. URL Building
- **Function**: `code-review-minimal--api-url`
- **Line**: 377-384
- **Pattern**: Base URL + path segments joined with "/"

### 4. Response Parsing
- **HTTP Status**: `code-review-minimal--http-status-code` (Line 429-434)
- **Response Body**: `code-review-minimal--response-body` (Line 436-442)
- **JSON Parse**: `code-review-minimal--parse-response` (Line 444-454)

---

## GitHub-Specific HTTP Calls

### Fetch PR Comments
- **Function**: `code-review-minimal--github-fetch-comments`
- **Line**: 684-703
- **Endpoint**: `GET /repos/{owner}/{repo}/pulls/{pr}/comments`
- **Line 694-696**: URL construction
- **Line 697-703**: HTTP request + callback to process comments

### Post PR Comment (Two-Step)
#### Step 1: Get PR Head SHA
- **Function**: `code-review-minimal--github-post-comment`
- **Line**: 724-763
- **Endpoint**: `GET /repos/{owner}/{repo}/pulls/{pr}`
- **Line**: 735-737 (URL construction)
- **Line**: 738-742 (Extract head SHA)

#### Step 2: Post Comment
- **Endpoint**: `POST /repos/{owner}/{repo}/pulls/{pr}/comments`
- **Line**: 746-748 (URL construction)
- **Line**: 749-753 (Payload: body, path, line, side=RIGHT, commit_id)
- **Line**: 754-763 (HTTP request)

### Update PR Comment
- **Function**: `code-review-minimal--github-update-comment`
- **Line**: 765-785
- **Endpoint**: `PATCH /repos/{owner}/{repo}/pulls/comments/{note_id}`
- **Line**: 773-775 (URL + method)
- **Line**: 778 (Payload: just body)

---

## GitLab/Gongfeng-Specific HTTP Calls

### Fetch MR Comments (Two-Step)

#### Step 1: Resolve MR IID to ID
- **Function**: `code-review-minimal--gitlab-resolve-mr-id`
- **Line**: 501-521
- **Endpoint**: `GET /projects/{project_id}/merge_request/iid/{iid}`
- **Line**: 506-509 (URL construction)
- **Line**: 512-521 (HTTP request)
- **Critical**: Returns `id` field needed for next step

#### Step 2: Fetch Comments
- **Function**: `code-review-minimal--gitlab-fetch-comments`
- **Line**: 525-548
- **Endpoint**: `GET /projects/{project_id}/merge_requests/{mr_id}/notes?per_page=100`
- **Line**: 534-539 (URL construction with pagination)
- **Line**: 540-548 (HTTP request + process notes)

### Post MR Comment
- **Function**: `code-review-minimal--gitlab-post-comment`
- **Line**: 591-617
- **Endpoint**: `POST /projects/{project_id}/merge_requests/{mr_id}/notes`
- **Line**: 600-603 (URL construction)
- **Line**: 604-607 (Payload):
  - `body`: comment text
  - `path`: relative file path
  - `line`: line number (as string!)
  - `line_type`: "new" (for new code side)
- **Line**: 608-617 (HTTP request)

### Update MR Comment
- **Function**: `code-review-minimal--gitlab-update-comment`
- **Line**: 619-639
- **Endpoint**: `PUT /projects/{project_id}/merge_requests/{mr_id}/notes/{note_id}`
- **Line**: 625-628 (URL construction)
- **Line**: 629 (Payload: just body)
- **Line**: 630-639 (HTTP request)

### Resolve MR Comment
- **Function**: `code-review-minimal--gitlab-resolve-comment`
- **Line**: 641-663
- **Endpoint**: `PUT /projects/{project_id}/merge_requests/{mr_id}/notes/{note_id}`
- **Line**: 649-652 (URL construction)
- **Line**: 656 (Payload: body + resolve_state=2)
- **Line**: 653-663 (HTTP request)

---

## Project Information Resolution

### GitHub Project Info
- **Function**: `code-review-minimal--github-ensure-project-info`
- **Line**: 667-682
- **Step 1**: Parse git remote URL (Line 670-671)
- **Step 2**: Extract owner/repo (Line 671)
- **Storage**: `code-review-minimal--project-info` as alist

### GitLab/Gongfeng Project Info
- **Function**: `code-review-minimal--gitlab-ensure-project-id`
- **Line**: 486-499
- **Step 1**: Parse git remote URL (Line 489-490)
- **Step 2**: URL-hexify namespace/project (Line 495)
- **Storage**: `code-review-minimal--project-info` with `project-id` key

### Git Remote URL Parsing
- **Function**: `code-review-minimal--git-remote-url`
- **Line**: 310-315
- **Uses**: `git remote get-url origin`

---

## Backend Detection

- **Function**: `code-review-minimal--detect-backend`
- **Line**: 169-184
- **Priority Order**:
  1. Check for "git.woa.com" → 'gongfeng
  2. Check for "github" → 'github
  3. Check for "gitlab" → 'gitlab
  4. Return nil if unknown

---

## Token Management

### Get Token
- **Function**: `code-review-minimal--get-token`
- **Line**: 274-280
- **Dispatch**: Select token based on backend

### Set Token (Interactive)
- **Function**: `code-review-minimal-set-token`
- **Line**: 283-293
- **Interactive**: `M-x code-review-minimal-set-token`

### Assert Token Exists
- **Function**: `code-review-minimal--assert-token`
- **Line**: 302-306
- **Error**: If token not set or empty

---

## Backend Dispatch Functions

All HTTP operations dispatched via these functions based on `code-review-minimal--current-backend`:

### Fetch Comments
- **Function**: `code-review-minimal--fetch-comments`
- **Line**: 956-961
- **Routes**:
  - 'github → `code-review-minimal--github-fetch-comments`
  - 'gitlab/'gongfeng → `code-review-minimal--gitlab-fetch-comments`

### Post Comment
- **Function**: `code-review-minimal--post-comment`
- **Line**: 963-968

### Update Comment
- **Function**: `code-review-minimal--update-comment`
- **Line**: 970-975

### Resolve Comment
- **Function**: `code-review-minimal--resolve-comment`
- **Line**: 977-982

---

## Customizable Configuration

### Token Variables
- `code-review-minimal-github-token` (Line 66)
- `code-review-minimal-gitlab-token` (Line 73)
- `code-review-minimal-gongfeng-token` (Line 80)
- `code-review-minimal-private-token` (Line 105) - deprecated

### API Base URLs
- `code-review-minimal-github-base-url` (Line 87)
  - Default: "https://api.github.com"
  - Enterprise: "https://your-github-enterprise.com/api/v3"

- `code-review-minimal-gitlab-base-url` (Line 93)
  - Default: "https://gitlab.com/api/v4"
  - Self-hosted: "https://your-gitlab.com/api/v4"

- `code-review-minimal-gongfeng-base-url` (Line 99)
  - Default: "https://git.woa.com/api/v3"

---

## Caching Layer

### In-Memory Caches
- `code-review-minimal--iid-cache` (Line 188)
  - Maps: git-root → MR/PR IID
  
- `code-review-minimal--backend-cache` (Line 191)
  - Maps: git-root → backend symbol

### Persistent Cache (Git directory)
- File: `.git/code-review-minimal-iid`
  - Stores: MR/PR IID number
  
- File: `.git/code-review-minimal-backend`
  - Stores: backend name (github/gitlab/gongfeng)

### Cache Functions
- Load IID: `code-review-minimal--load-cached-iid` (Line 204-217)
- Save IID: `code-review-minimal--save-iid` (Line 219-224)
- Load Backend: `code-review-minimal--load-cached-backend` (Line 226-238)
- Save Backend: `code-review-minimal--save-backend` (Line 240-245)

---

## Error Handling

### HTTP Error Detection (Lines 413-426)
```elisp
(plist-get status :error)           ;; Network errors
(>= http-status 400)                ;; HTTP 4xx/5xx
```

### Message Logging
All errors logged to `*Messages*` buffer with "code-review-minimal:" prefix

---

## Entry Points (Public Commands)

1. **Enable Mode**: `code-review-minimal-mode` (Line 1071)
2. **Add Comment**: `code-review-minimal-add-comment` (Line 1014)
3. **Edit Comment**: `code-review-minimal-edit-comment` (Line 1025)
4. **Resolve Comment**: `code-review-minimal-resolve-comment` (Line 1050)
5. **Refresh**: `code-review-minimal-refresh` (Line 1039)
6. **Set MR/PR IID**: `code-review-minimal-set-mr-iid` (Line 996)
7. **Set Backend**: `code-review-minimal-set-backend-for-repo` (Line 1005)
8. **Set Token**: `code-review-minimal-set-token` (Line 283)

