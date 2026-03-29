# code-review-minimal (WIP)

NOTE: this is not fully implemented yet.

A lightweight Emacs minor mode for performing code review directly inside Emacs against GitHub Pull Requests, GitLab Merge Requests, and Gongfeng (Tencent GitLab) MRs.

## Features

- **Multi-platform support**: Works with GitHub, GitLab, and Gongfeng (git.woa.com)
- **Auto-detection**: Automatically detects the backend from git remote URL
- **Overlay-based comments**: Displays review comments as overlays directly in the code
- **Interactive commenting**: Add comments by selecting a region and submitting
- **Thread management**: View resolved/unresolved comment threads
- **Real-time refresh**: Fetch the latest comments from the API
- **Legacy compatibility**: Maintains backward compatibility with `gf-code-review`

## Installation

### Manual Installation

1. Clone or download this repository
2. Add to your Emacs load path:
   ```elisp
   (add-to-list 'load-path "/path/to/code-review-minimal")
   (require 'code-review-minimal)
   ```

### With use-package

```elisp
(use-package code-review-minimal
  :load-path "~/path/to/code-review-minimal"
  :custom
  ;; GitHub configuration
  (code-review-minimal-github-token "your-github-token")
  ;; OR GitLab configuration
  (code-review-minimal-gitlab-token "your-gitlab-token")
  ;; OR Gongfeng configuration
  (code-review-minimal-gongfeng-token "your-gongfeng-token"))
```

## Configuration

### Authentication

You need to set at least one of these tokens based on your platform:

| Platform | Variable | How to create |
|----------|----------|---------------|
| GitHub | `code-review-minimal-github-token` | https://github.com/settings/tokens (requires `repo` scope) |
| GitLab | `code-review-minimal-gitlab-token` | GitLab → User Settings → Access Tokens (requires `api` scope) |
| Gongfeng | `code-review-minimal-gongfeng-token` | git.woa.com → User Settings → Access Tokens |

### Optional Settings

```elisp
;; Force a specific backend (auto-detected if nil)
(setq code-review-minimal-backend 'github)  ; or 'gitlab, 'gongfeng

;; Custom API URLs (for GitHub Enterprise or self-hosted GitLab)
(setq code-review-minimal-github-base-url "https://github.company.com/api/v3")
(setq code-review-minimal-gitlab-base-url "https://gitlab.company.com/api/v4")
```

## Usage

### Quick Start

1. Open any file that belongs to a git repository with an MR/PR
2. Enable the mode: `M-x code-review-minimal-mode`
3. The backend is auto-detected from the git remote URL
4. Enter the MR/PR IID when prompted (or it will use cached value)
5. Comments will be fetched and displayed as overlays

### Commands

| Command | Description |
|---------|-------------|
| `code-review-minimal-mode` | Toggle code review mode |
| `code-review-minimal-add-comment` | Add a comment on selected region |
| `code-review-minimal-edit-comment` | Edit the comment at point |
| `code-review-minimal-refresh` | Re-fetch and redisplay all comments |
| `code-review-minimal-resolve-comment` | Mark the comment at point as resolved |
| `code-review-minimal-set-mr-iid` | Set the MR/PR IID for current repo |
| `code-review-minimal-set-backend-for-repo` | Override auto-detected backend |
| `code-review-minimal-set-token` | Interactively set authentication token |

### Adding Comments

1. Select a region of code (transient mark mode)
2. Run `M-x code-review-minimal-add-comment`
3. Type your comment in the overlay that appears
4. Press `C-c C-c` to submit or `C-c C-k` to cancel

### Managing Threads

- Resolved comments are shown with a green face
- Unresolved comments are shown with a blue face
- Use `M-x code-review-minimal-resolve-comment` on a comment line to resolve it

### Setting MR/PR IID

If auto-detection fails or you want to review a specific MR/PR:
```
M-x code-review-minimal-set-mr-iid
```
This caches the IID per repository in `.git/code-review-minimal-iid`.

## Supported Platforms

| Platform | Domain | API Version |
|----------|--------|-------------|
| GitHub | github.com | REST API v3 |
| GitHub Enterprise | Custom | REST API v3 |
| GitLab | gitlab.com | API v4 |
| Self-hosted GitLab | Custom | API v4 |
| Gongfeng (工蜂) | git.woa.com | API v3 |

## Backend Detection

The mode automatically detects the backend from the git remote URL:

```elisp
;; Example remote URLs and their detected backends:
"https://github.com/user/repo.git"     → github
"git@github.com:user/repo.git"         → github
"https://gitlab.com/user/repo.git"     → gitlab
"https://git.woa.com/user/repo.git"    → gongfeng
```

## Customization

### Faces

You can customize the appearance of comment overlays:

- `code-review-minimal-comment-face` - Default comment overlay
- `code-review-minimal-resolved-face` - Resolved status indicator
- `code-review-minimal-unresolved-face` - Unresolved status indicator
- `code-review-minimal-resolved-body-face` - Resolved comment body
- `code-review-minimal-input-face` - Comment input overlay
- `code-review-minimal-header-face` - Comment header line

### Example Customization

```elisp
(custom-set-faces
 '(code-review-minimal-comment-face
   ((t (:background "#fff3cd" :foreground "#856404" :box (:line-width 1 :color "#ffc107"))))))
```

## Requirements

- Emacs 27.1 or later
- `json` library (built-in)
- `url` library (built-in)

## How It Works

1. **Backend Detection**: Parses git remote URL to determine platform (GitHub/GitLab/Gongfeng)
2. **IID Resolution**: Finds the MR/PR IID by matching current branch against open MRs/PRs
3. **Comment Fetching**: Retrieves comments via platform's REST API
4. **Overlay Display**: Renders comments as overlays positioned at the correct line numbers
5. **Comment Submission**: POSTs new comments back to the API with proper positioning

## Troubleshooting

### Comments not showing

- Ensure your token is set correctly
- Check that you're on a branch with an open MR/PR
- Run `M-x code-review-minimal-set-mr-iid` to manually specify the MR/PR number
- Check `*Messages*` buffer for API errors

### Wrong backend detected

- Set `code-review-minimal-backend` explicitly:
  ```elisp
  (setq code-review-minimal-backend 'github)
  ```
- Or use `M-x code-review-minimal-set-backend-for-repo` to persist for current repository

### API errors

- Verify your token has the correct scopes
- Check network connectivity
- For GitHub Enterprise/GitLab self-hosted, verify `code-review-minimal-*-base-url` is set correctly

## License

MIT License

Copyright (c) 2024 phye

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
