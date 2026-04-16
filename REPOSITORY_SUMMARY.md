# Repository Exploration Summary

Generated: 2026-04-16

---

## Quick Stats

| Metric | Value |
|--------|-------|
| **Total Files** | 3 (.el, .md, .gitignore) |
| **Main Code File** | code-review-minimal.el (1125 lines) |
| **External Dependencies** | 0 (Emacs 27.1+ built-ins only) |
| **Supported Backends** | 3 (GitHub, GitLab, Gongfeng) |
| **HTTP Endpoints Called** | ~13 total |
| **Public Commands** | 8 |
| **Internal Functions** | 40+ |
| **Git History** | 3 commits |

---

## Files Overview

### 1. **code-review-minimal.el** (1125 lines, ~52KB)
Main package implementing all functionality
- Lines 1-40: Header, commentary, license
- Lines 42-46: Dependencies (json, url, url-http, cl-lib, subr-x)
- Lines 48-166: Configuration & Customization
- Lines 167-184: Backend Detection
- Lines 186-245: Caching (in-memory + .git/)
- Lines 248-270: Buffer-local State
- Lines 272-306: Token Management
- Lines 308-351: Remote URL Parsing
- Lines 353-373: Backend Selection
- Lines 375-455: HTTP Layer (core request handler)
- Lines 484-587: GitLab/Gongfeng Backend
- Lines 665-791: GitHub Backend
- Lines 793-848: Overlay Rendering
- Lines 850-952: Input Overlay & Comment Input
- Lines 954-982: Backend Dispatch Functions
- Lines 984-1118: Public Commands & Minor Mode
- Lines 1120-1125: Provide Statement

### 2. **README.md** (212 lines)
User documentation
- Installation instructions
- Configuration guide
- Usage examples
- Command reference
- Supported platforms & backends

### 3. **.gitignore** (empty)
Placeholder for ignored files

### 4. **ANALYSIS.md** (Generated)
Comprehensive technical analysis with all details

### 5. **HTTP_ENDPOINTS.md** (Generated)
Quick reference for all HTTP calls

### 6. **API_FLOW.md** (Generated)
Visual flow diagrams for all operations

---

## Supported Platforms

### GitHub (github.com or GitHub Enterprise)
- **API Version**: REST v3
- **Base URL**: https://api.github.com (customizable)
- **Auth**: Bearer token in Authorization header
- **Token Variable**: `code-review-minimal-github-token`
- **Endpoints Used**: 4
  - GET /repos/{owner}/{repo}/pulls/{pr}/comments
  - GET /repos/{owner}/{repo}/pulls/{pr}
  - POST /repos/{owner}/{repo}/pulls/{pr}/comments
  - PATCH /repos/{owner}/{repo}/pulls/comments/{id}

### GitLab (gitlab.com or self-hosted)
- **API Version**: v4
- **Base URL**: https://gitlab.com/api/v4 (customizable)
- **Auth**: PRIVATE-TOKEN header
- **Token Variable**: `code-review-minimal-gitlab-token`
- **Endpoints Used**: 5
  - GET /projects/{id}/merge_request/iid/{iid}
  - GET /projects/{id}/merge_requests/{mr_id}/notes
  - POST /projects/{id}/merge_requests/{mr_id}/notes
  - PUT /projects/{id}/merge_requests/{mr_id}/notes/{note_id}
  - PUT /projects/{id}/merge_requests/{mr_id}/notes/{note_id} (resolve)

### Gongfeng (Tencent GitLab, git.woa.com)
- **API Version**: v3 (note: v3, not v4)
- **Base URL**: https://git.woa.com/api/v3 (customizable)
- **Auth**: PRIVATE-TOKEN header
- **Token Variable**: `code-review-minimal-gongfeng-token` or `code-review-minimal-private-token` (legacy)
- **Endpoints Used**: Same as GitLab (5)
- **URL Encoding**: namespace/project → namespace%2Fproject

---

## Key Features

### 1. **Multi-Backend Support**
- Auto-detect backend from git remote URL
- Manual backend override
- Per-repository caching of backend choice

### 2. **Authentication**
- Per-backend token configuration
- Token validation before API calls
- Interactive token setup: `M-x code-review-minimal-set-token`

### 3. **Comment Display**
- Fetch comments/notes from PR/MR
- Render as overlays in editor
- Show thread structure (root + replies)
- Color-coded by status (resolved/unresolved)

### 4. **Comment Management**
- Add new comments on selected lines
- Edit existing comments
- Resolve comments (GitLab/Gongfeng only)

### 5. **Data Caching**
- In-memory cache (per Emacs session)
- Persistent cache in .git/ directory
- Fast subsequent mode enable

### 6. **Error Handling**
- Network error detection
- HTTP error status checking
- JSON parse error handling
- User-friendly error messages to *Messages* buffer

---

## HTTP Request Pattern

All HTTP calls follow this async pattern:

```elisp
code-review-minimal--http-request(backend, method, url, payload, callback)
  ├─ Validate token
  ├─ Build auth headers (backend-specific)
  ├─ JSON-encode payload
  ├─ Call url-retrieve (async)
  └─ Parse response when arrives
      ├─ Extract HTTP status
      ├─ Check for errors
      ├─ Parse JSON
      └─ Call user callback with result
```

No blocking/synchronous HTTP calls - all operations are non-blocking.

---

## Authentication Handling

### Token Storage
- **Not encrypted** on disk by default (user responsibility)
- Recommended: Use environment variables or .authinfo.gpg
- Customizable variables: `code-review-minimal-{github,gitlab,gongfeng}-token`

### Header Construction
**GitHub**:
```
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
```

**GitLab/Gongfeng**:
```
PRIVATE-TOKEN: <token>
Content-Type: application/json; charset=utf-8
```

---

## Project Information Resolution

### GitHub
1. Parse git remote: `git remote get-url origin`
2. Extract owner/repo using regex
3. Store as: `((owner . "owner") (repo . "repo"))`

### GitLab/Gongfeng
1. Parse git remote: `git remote get-url origin`
2. Extract namespace/project using regex
3. URL-encode: namespace%2Fproject (for API)
4. Store as: `((project-id . "namespace%2Fproject"))`

### Supported Remote Formats
- SSH: `git@github.com:owner/repo.git`
- HTTPS: `https://github.com/owner/repo.git`
- HTTPS no suffix: `https://github.com/owner/repo`
- GitHub Enterprise: Both SSH & HTTPS variants
- With/without `.git` suffix: All supported

---

## MR/PR IID Resolution

### GitHub
- Use PR number directly from URL
- No resolution needed (PR number = global ID)

### GitLab/Gongfeng
- User provides IID (project-specific ID)
- API call needed to resolve IID → global MR ID
- Endpoint: `GET /projects/{id}/merge_request/iid/{iid}`
- Response includes: `id` (global MR ID used for subsequent calls)

---

## Backend Detection Priority

```
git remote URL analysis:
  1. Contains "git.woa.com" → gongfeng
  2. Contains "github.com" or "github" → github  
  3. Contains "gitlab" → gitlab
  4. Else → nil (error)
```

---

## Caching Mechanism

### In-Memory (Per Emacs Session)
- `code-review-minimal--iid-cache`: git-root → MR IID
- `code-review-minimal--backend-cache`: git-root → backend symbol

### Persistent (Per Repository)
- `.git/code-review-minimal-iid`: MR/PR number
- `.git/code-review-minimal-backend`: backend name

### Lookup Strategy
1. Check in-memory cache (fast)
2. Check .git files (if session restart)
3. Detect/prompt if not found
4. Save to both for next time

---

## Public Commands (API)

### Code Review Mode
- `M-x code-review-minimal-mode` - Toggle review mode

### Comment Operations
- `M-x code-review-minimal-add-comment` - Add comment to selected region
- `M-x code-review-minimal-edit-comment` - Edit comment at point
- `M-x code-review-minimal-resolve-comment` - Resolve comment at point
- `M-x code-review-minimal-refresh` - Re-fetch all comments

### Configuration
- `M-x code-review-minimal-set-token` - Set authentication token
- `M-x code-review-minimal-set-mr-iid` - Set PR/MR number
- `M-x code-review-minimal-set-backend-for-repo` - Override backend detection

---

## Entry Points for Integration

### For Adding Support of Additional Backend

Implement these functions with backend name (e.g., `myservice`):
1. `code-review-minimal--myservice-ensure-project-info` - Parse git remote
2. `code-review-minimal--myservice-fetch-comments` - Fetch comments
3. `code-review-minimal--myservice-post-comment` - Post new comment
4. `code-review-minimal--myservice-update-comment` - Update existing comment
5. `code-review-minimal--myservice-resolve-comment` - Resolve comment (if supported)

Update dispatch functions (lines 956-982):
- `code-review-minimal--fetch-comments`
- `code-review-minimal--post-comment`
- `code-review-minimal--update-comment`
- `code-review-minimal--resolve-comment`

Update backend detection (line 169-184):
- Add pattern matching for new backend domain

---

## Data Flow Summary

```
User enables mode
    ↓
Detect backend from git remote
    ↓
Validate token for backend
    ↓
Get MR/PR IID (or use cached)
    ↓
Fetch comments via HTTP (async)
    ↓
Parse JSON response
    ↓
Create overlays for comments
    ↓
Display in editor
    ↓
User can add/edit/resolve comments
    ↓
Each action triggers HTTP call (async)
    ↓
Refresh display with updated data
```

---

## Configuration Examples

### GitHub Setup
```elisp
(setq code-review-minimal-github-token "ghp_xxxxxxxxxxxx")
(setq code-review-minimal-github-base-url "https://api.github.com")
```

### GitLab Self-Hosted Setup
```elisp
(setq code-review-minimal-gitlab-token "glpat-xxxxxxxxxxxx")
(setq code-review-minimal-gitlab-base-url "https://gitlab.company.com/api/v4")
```

### Gongfeng Setup
```elisp
(setq code-review-minimal-gongfeng-token "xxxxxxxxxxxx")
(setq code-review-minimal-gongfeng-base-url "https://git.woa.com/api/v3")
```

### use-package Integration
```elisp
(use-package code-review-minimal
  :load-path "~/code-review-minimal"
  :custom
  (code-review-minimal-github-token (getenv "GITHUB_TOKEN"))
  (code-review-minimal-gitlab-token (getenv "GITLAB_TOKEN")))
```

---

## Known Limitations

1. **GitHub**: Cannot resolve comments via API (web UI only)
2. **Single file at a time**: Reviews current file only
3. **No authentication persistence**: Tokens stored in Emacs variables
4. **WIP status**: Some features still being implemented
5. **Sync requirement**: User must know PR/MR number (no auto-detection from branch)

---

## Dependencies

### Package Requirements
- **Emacs**: 27.1 or later
- **No external packages**: All using built-in Emacs libraries

### Built-in Libraries Used
- `json.el` - JSON encoding/decoding
- `url.el` - HTTP client
- `url-http.el` - HTTP-specific functionality
- `cl-lib.el` - Common Lisp compatibility
- `subr-x.el` - Extra subroutine utilities

---

## Testing the HTTP Layer

Key functions to test/debug:

1. **HTTP Request Core**: `code-review-minimal--http-request`
   - Test with different HTTP methods (GET, POST, PUT, PATCH)
   - Test error handling (4xx, 5xx, network errors)

2. **Backend Detection**: `code-review-minimal--detect-backend`
   - Test with different git remote URLs

3. **URL Parsing**: `code-review-minimal--parse-github-repo` / `code-review-minimal--parse-gitlab-project-path`
   - Test various remote URL formats (SSH, HTTPS, with/without .git)

4. **API URL Construction**: `code-review-minimal--api-url`
   - Test path segment joining

5. **Authentication**: `code-review-minimal--make-auth-headers`
   - Test different auth header formats

---

## Recent Git History

```
39bdbfd Add WIP
829cd74 change license to MIT
61b889a initial commit add code-review
```

---

## Project Status

**Status**: WIP (Work in Progress) - not fully implemented yet

**Functional Features**:
- ✅ Multi-backend support (GitHub, GitLab, Gongfeng)
- ✅ Auto-backend detection
- ✅ Fetch and display comments
- ✅ Add comments
- ✅ Edit comments
- ✅ Resolve comments (GitLab/Gongfeng)
- ✅ Overlay rendering
- ✅ Caching mechanism

**Potential Areas for Development**:
- GitHub comment resolution
- More robust error handling
- Better UI/UX
- Performance optimizations
- Additional backend support

---

## Summary

This is a minimal but functional Emacs-based code review tool supporting three major git platforms. It uses only built-in Emacs HTTP libraries and implements async request patterns. The codebase is well-structured with clear backend abstraction, making it easy to add new platform support. The HTTP layer is the central component, with all operations flowing through `code-review-minimal--http-request`.

