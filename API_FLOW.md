# API Flow Diagrams & Architecture

## 1. Initialization Flow

```
User runs: M-x code-review-minimal-mode
    │
    ├─→ code-review-minimal--ensure-backend()
    │   ├─→ code-review-minimal--load-cached-backend() [.git/code-review-minimal-backend]
    │   │   └─→ Return if found
    │   └─→ Else: Detect from git remote
    │       ├─→ code-review-minimal--git-remote-url()
    │       │   └─→ `git remote get-url origin`
    │       └─→ code-review-minimal--detect-backend(remote)
    │           ├─→ Check "git.woa.com" → gongfeng
    │           ├─→ Check "github.com" → github
    │           └─→ Check "gitlab" → gitlab
    │
    ├─→ code-review-minimal--assert-token(backend)
    │   └─→ Error if token not configured
    │
    ├─→ Prompt user for MR/PR IID (or load cached)
    │   └─→ code-review-minimal--load-cached-iid() [.git/code-review-minimal-iid]
    │
    └─→ code-review-minimal--fetch-comments()
        ├─→ GitHub: code-review-minimal--github-fetch-comments()
        └─→ GitLab/Gongfeng: code-review-minimal--gitlab-fetch-comments()
```

---

## 2. GitHub Fetch Comments Flow

```
code-review-minimal--github-fetch-comments
    │
    ├─→ code-review-minimal--github-ensure-project-info()
    │   ├─→ code-review-minimal--git-remote-url()
    │   └─→ code-review-minimal--parse-github-repo(remote)
    │       └─→ Extract: (owner . repo)
    │
    └─→ code-review-minimal--http-request('github, "GET", URL, nil, CALLBACK)
        │
        ├─ URL: https://api.github.com/repos/{owner}/{repo}/pulls/{pr}/comments
        │
        ├─ Headers:
        │  ├─ Authorization: Bearer <token>
        │  ├─ Accept: application/vnd.github+json
        │  └─ X-GitHub-Api-Version: 2022-11-28
        │
        └─ Callback: code-review-minimal--github-process-comments(comments, rel_path)
            └─→ For each comment matching rel_path:
                └─→ code-review-minimal--insert-discussion-overlay()
```

---

## 3. GitLab/Gongfeng Fetch Comments Flow

```
code-review-minimal--gitlab-fetch-comments
    │
    ├─→ code-review-minimal--gitlab-ensure-project-id()
    │   ├─→ code-review-minimal--git-remote-url()
    │   └─→ code-review-minimal--parse-gitlab-project-path(remote)
    │       └─→ URL-hexify: namespace/project → namespace%2Fproject
    │
    ├─→ code-review-minimal--gitlab-resolve-mr-id(CALLBACK)
    │   │
    │   └─→ code-review-minimal--http-request('gongfeng, "GET", URL, nil, CALLBACK)
    │       │
    │       ├─ URL: https://git.woa.com/api/v3/projects/{project_id}/merge_request/iid/{iid}
    │       │
    │       ├─ Headers:
    │       │  ├─ PRIVATE-TOKEN: <token>
    │       │  └─ Content-Type: application/json; charset=utf-8
    │       │
    │       └─ Callback: Extract MR ID, then continue to next step
    │
    └─→ code-review-minimal--http-request('gongfeng, "GET", URL, nil, CALLBACK)
        │
        ├─ URL: https://git.woa.com/api/v3/projects/{project_id}/merge_requests/{mr_id}/notes?per_page=100
        │
        ├─ Headers:
        │  ├─ PRIVATE-TOKEN: <token>
        │  └─ Content-Type: application/json; charset=utf-8
        │
        └─ Callback: code-review-minimal--gitlab-process-notes(notes, rel_path)
            ├─→ Index notes by ID (parent_id relationships)
            ├─→ For each root note matching rel_path:
            │   └─→ code-review-minimal--insert-discussion-overlay(line, thread, resolved, id)
            └─→ Display: "X thread(s) in this file, Y total notes"
```

---

## 4. Post Comment (Add) - GitHub

```
User selects text and runs: M-x code-review-minimal-add-comment
    │
    ├─→ code-review-minimal--open-input-overlay(beg, end)
    │   └─→ Show input buffer below selection
    │
    └─→ User presses C-c C-c to submit
        │
        └─→ code-review-minimal--submit-comment()
            │
            ├─→ Extract user text from input buffer
            │
            └─→ code-review-minimal--post-comment(beg, end, body)
                │
                └─→ code-review-minimal--github-post-comment(beg, end, body)
                    │
                    ├─→ STEP 1: Get PR head SHA
                    │   │
                    │   └─→ code-review-minimal--http-request('github, "GET", PR_URL, nil, CALLBACK)
                    │       │
                    │       ├─ URL: https://api.github.com/repos/{owner}/{repo}/pulls/{pr}
                    │       │
                    │       └─ Callback: Extract head.sha from response
                    │
                    └─→ STEP 2: Post comment with commit SHA
                        │
                        └─→ code-review-minimal--http-request('github, "POST", URL, PAYLOAD, CALLBACK)
                            │
                            ├─ URL: https://api.github.com/repos/{owner}/{repo}/pulls/{pr}/comments
                            │
                            ├─ Headers:
                            │  ├─ Authorization: Bearer <token>
                            │  ├─ Accept: application/vnd.github+json
                            │  └─ X-GitHub-Api-Version: 2022-11-28
                            │
                            ├─ Payload:
                            │  {
                            │    "body": "User's comment",
                            │    "path": "src/file.js",
                            │    "line": 42,
                            │    "side": "RIGHT",
                            │    "commit_id": "abc123def..."
                            │  }
                            │
                            └─ Callback: Refresh display via code-review-minimal--github-fetch-comments()
```

---

## 5. Post Comment (Add) - GitLab/Gongfeng

```
User selects text and runs: M-x code-review-minimal-add-comment
    │
    ├─→ code-review-minimal--open-input-overlay(beg, end)
    │   └─→ Show input buffer below selection
    │
    └─→ User presses C-c C-c to submit
        │
        └─→ code-review-minimal--submit-comment()
            │
            ├─→ Extract user text from input buffer
            │
            └─→ code-review-minimal--post-comment(beg, end, body)
                │
                └─→ code-review-minimal--gitlab-post-comment(beg, end, body)
                    │
                    ├─→ code-review-minimal--gitlab-resolve-mr-id(CALLBACK)
                    │   └─→ Resolve IID to MR ID (same as fetch flow)
                    │
                    └─→ code-review-minimal--http-request('gongfeng, "POST", URL, PAYLOAD, CALLBACK)
                        │
                        ├─ URL: https://git.woa.com/api/v3/projects/{project_id}/merge_requests/{mr_id}/notes
                        │
                        ├─ Headers:
                        │  ├─ PRIVATE-TOKEN: <token>
                        │  └─ Content-Type: application/json; charset=utf-8
                        │
                        ├─ Payload:
                        │  {
                        │    "body": "User's comment",
                        │    "path": "src/file.js",
                        │    "line": "42",
                        │    "line_type": "new"
                        │  }
                        │
                        └─ Callback: Refresh display via code-review-minimal--gitlab-fetch-comments()
```

---

## 6. Update Comment - GitHub

```
User at comment line + M-x code-review-minimal-edit-comment
    │
    ├─→ Find overlay at point
    │
    ├─→ code-review-minimal--open-input-overlay(line, line, note_id, body)
    │   └─→ Show input buffer with existing comment text
    │
    └─→ User modifies text and presses C-c C-c
        │
        └─→ code-review-minimal--submit-comment()
            │
            └─→ code-review-minimal--update-comment(note_id, body)
                │
                └─→ code-review-minimal--github-update-comment(note_id, body)
                    │
                    └─→ code-review-minimal--http-request('github, "PATCH", URL, PAYLOAD, CALLBACK)
                        │
                        ├─ URL: https://api.github.com/repos/{owner}/{repo}/pulls/comments/{note_id}
                        │
                        ├─ Headers:
                        │  ├─ Authorization: Bearer <token>
                        │  ├─ Accept: application/vnd.github+json
                        │  └─ X-GitHub-Api-Version: 2022-11-28
                        │
                        ├─ Payload:
                        │  {
                        │    "body": "Updated comment"
                        │  }
                        │
                        └─ Callback: Refresh display via code-review-minimal--github-fetch-comments()
```

---

## 7. Resolve Comment - GitLab/Gongfeng Only

```
User at comment line + M-x code-review-minimal-resolve-comment
    │
    ├─→ Find overlay at point
    │
    └─→ Check if already resolved
        │
        └─→ code-review-minimal--resolve-comment(overlay)
            │
            └─→ code-review-minimal--gitlab-resolve-comment(overlay)
                │
                ├─→ code-review-minimal--gitlab-resolve-mr-id(CALLBACK)
                │   └─→ Resolve IID to MR ID
                │
                └─→ code-review-minimal--http-request('gongfeng, "PUT", URL, PAYLOAD, CALLBACK)
                    │
                    ├─ URL: https://git.woa.com/api/v3/projects/{project_id}/merge_requests/{mr_id}/notes/{note_id}
                    │
                    ├─ Headers:
                    │  ├─ PRIVATE-TOKEN: <token>
                    │  └─ Content-Type: application/json; charset=utf-8
                    │
                    ├─ Payload:
                    │  {
                    │    "body": "Original comment",
                    │    "resolve_state": 2
                    │  }
                    │
                    └─ Callback: Refresh display via code-review-minimal--gitlab-fetch-comments()
                        └─→ Comments re-rendered with green "✓resolved" indicator

Note: GitHub doesn't have a native resolve API - shows message to use web UI
```

---

## 8. HTTP Request Handling Detail

```
code-review-minimal--http-request(backend, method, url, payload, callback)
    │
    ├─→ Validate token exists: code-review-minimal--assert-token(backend)
    │
    ├─→ Build headers: code-review-minimal--make-auth-headers(backend)
    │
    ├─→ JSON encode payload (if provided)
    │   └─→ encode-coding-string(json-encode(payload), 'utf-8)
    │
    ├─→ url-retrieve(url, RESPONSE_HANDLER, nil, t)
    │   │
    │   │ [HTTP request sent, waits for response...]
    │   │
    │   └─→ RESPONSE_HANDLER(status) called when response arrives
    │       │
    │       ├─→ Extract HTTP status: code-review-minimal--http-status-code()
    │       │   └─→ Regex search for "HTTP/X.X ###"
    │       │
    │       ├─→ Check for network error: (plist-get status :error)
    │       │
    │       ├─→ Check for HTTP 4xx/5xx: (>= http-status 400)
    │       │   └─→ Log error message to *Messages*
    │       │
    │       ├─→ Extract response body: code-review-minimal--response-body()
    │       │   └─→ Find empty line separator, get everything after
    │       │
    │       ├─→ Parse JSON: code-review-minimal--parse-response()
    │       │   └─→ json-read-from-string with alist/list/symbol types
    │       │
    │       └─→ Call user callback(parsed_result)
    │           └─→ Callback processes data and updates UI
    │
    └─→ Return immediately (async pattern)
```

---

## 9. Token Resolution Hierarchy

```
When code-review-minimal--get-token(backend) is called:
    │
    └─→ Switch on backend:
        │
        ├─→ 'github
        │   └─→ Return: code-review-minimal-github-token
        │
        ├─→ 'gitlab
        │   └─→ Return: code-review-minimal-gitlab-token
        │
        └─→ 'gongfeng
            └─→ Return: code-review-minimal-gongfeng-token
                OR: code-review-minimal-private-token (deprecated fallback)

Before making ANY HTTP request:
    │
    └─→ code-review-minimal--assert-token(backend)
        └─→ Signal error if token is nil or empty string
```

---

## 10. Backend Detection Decision Tree

```
code-review-minimal--detect-backend(remote_url)
    │
    ├─→ Contains "git.woa.com"?
    │   └─→ YES: Return 'gongfeng
    │
    ├─→ Contains "github.com" or "github"?
    │   └─→ YES: Return 'github
    │
    ├─→ Contains "gitlab"?
    │   └─→ YES: Return 'gitlab
    │
    └─→ Else: Return nil (unknown)

If backend is nil:
    │
    └─→ code-review-minimal--ensure-backend()
        └─→ User error: "Cannot detect backend, set code-review-minimal-backend"
```

---

## 11. Caching Strategy

```
code-review-minimal-mode enable:
    │
    ├─→ Backend selection:
    │   │
    │   ├─→ Check in-memory: code-review-minimal--backend-cache (HIT → use)
    │   │
    │   └─→ Check .git file: code-review-minimal--load-cached-backend()
    │       └─→ If found in file:
    │           ├─→ Load into memory
    │           └─→ Use it
    │       └─→ Else:
    │           ├─→ Detect from remote
    │           └─→ Save to both in-memory + .git file for next time
    │
    └─→ MR/PR IID selection:
        │
        ├─→ Check in-memory: code-review-minimal--iid-cache (HIT → use)
        │
        └─→ Check .git file: code-review-minimal--load-cached-iid()
            └─→ If found in file:
                ├─→ Load into memory
                └─→ Use it
            └─→ Else:
                ├─→ Prompt user
                └─→ Save to both in-memory + .git file for next time

Per-repo cache files:
    │
    ├─→ .git/code-review-minimal-backend
    │   └─→ Content: "github" or "gitlab" or "gongfeng"
    │
    └─→ .git/code-review-minimal-iid
        └─→ Content: "123" (PR/MR number)
```

---

## 12. Multi-Backend URL Construction

```
code-review-minimal--api-url(backend, segment1, segment2, ...)
    │
    ├─→ Get base URL based on backend:
    │   │
    │   ├─→ 'github: "https://api.github.com" (or custom via code-review-minimal-github-base-url)
    │   │
    │   ├─→ 'gitlab: "https://gitlab.com/api/v4" (or custom)
    │   │
    │   └─→ 'gongfeng: "https://git.woa.com/api/v3" (or custom)
    │
    └─→ Join with segments: base + "/" + join(segments, "/")

Examples:
    code-review-minimal--api-url('github, "repos", "owner", "repo", "pulls", "123", "comments")
        → "https://api.github.com/repos/owner/repo/pulls/123/comments"

    code-review-minimal--api-url('gongfeng, "projects", "ns%2Fproj", "merge_requests", "999", "notes")
        → "https://git.woa.com/api/v3/projects/ns%2Fproj/merge_requests/999/notes"
```

---

## 13. Error Recovery

```
HTTP request fails:
    │
    ├─→ Network error (plist-get status :error)
    │   └─→ Message: "code-review-minimal: HTTP error %S"
    │
    ├─→ HTTP 400+
    │   └─→ Message: "code-review-minimal: HTTP %d for %s\n  response: %s"
    │       └─→ Response truncated to 400 chars
    │
    └─→ JSON parse error
        └─→ Message: "code-review-minimal: JSON parse error: %S"

User action:
    │
    ├─→ Check *Messages* buffer for error
    ├─→ Verify token is set correctly
    ├─→ Verify network connectivity
    ├─→ Verify backend API URL is correct
    └─→ Re-run command to retry
```

