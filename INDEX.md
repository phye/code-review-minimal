# Code-Review-Minimal Repository Documentation Index

Generated: 2026-04-16

---

## 📋 Documentation Files

### 1. **README.md** (Original)
User-facing documentation with installation, configuration, and usage guide.
- **Audience**: End users
- **Contains**: Setup instructions, feature overview, command reference
- **Lines**: 211

---

### 2. **REPOSITORY_SUMMARY.md** ⭐ START HERE
High-level overview of the entire repository structure, architecture, and key components.
- **Audience**: Developers, maintainers
- **Best for**: Getting quick understanding of project scope
- **Contains**: Stats, file overview, features, dependencies, limitations
- **Lines**: 430
- **Key Sections**:
  - Quick Stats
  - Supported Platforms (GitHub, GitLab, Gongfeng)
  - Key Features
  - HTTP Request Pattern
  - Caching Mechanism
  - Entry Points for Integration

---

### 3. **ANALYSIS.md** 📖 DEEP DIVE
Comprehensive technical analysis with all implementation details.
- **Audience**: Developers, code reviewers
- **Best for**: Understanding architecture and implementation
- **Contains**: Detailed breakdowns of all components
- **Lines**: 655
- **Key Sections**:
  1. Files Structure (line numbers)
  2. Supported Backends & API Endpoints
  3. Authentication & HTTP Handling
  4. API Endpoint Mapping
  5. HTTP Request Flow - Detailed Examples
  6. Authentication Configuration
  7. Remote URL Parsing
  8. Dependencies
  9. Caching Mechanism
  10. Code Flow for Key Operations
  11. Data Structures
  12. Error Handling & Debugging
  13. Overlay Rendering & Display
  14. Architectural Summary
  15. Key Code Snippets by Functionality
  16. Security Considerations

---

### 4. **HTTP_ENDPOINTS.md** 🔗 QUICK REFERENCE
Fast lookup guide for all HTTP-related code with line numbers.
- **Audience**: Developers implementing new features
- **Best for**: Finding specific HTTP calls quickly
- **Contains**: Line numbers and code locations for all HTTP operations
- **Lines**: 266
- **Sections**:
  - Core HTTP Functions
  - GitHub-Specific HTTP Calls
  - GitLab/Gongfeng-Specific HTTP Calls
  - Project Information Resolution
  - Backend Detection
  - Token Management
  - Backend Dispatch Functions
  - Configuration Variables
  - Caching Layer
  - Error Handling
  - Entry Points

---

### 5. **API_FLOW.md** 🔄 VISUAL FLOWS
ASCII flow diagrams showing data flow for all major operations.
- **Audience**: Developers understanding workflow
- **Best for**: Visualizing multi-step operations
- **Contains**: 13 detailed flow diagrams
- **Lines**: 442
- **Flow Diagrams**:
  1. Initialization Flow
  2. GitHub Fetch Comments Flow
  3. GitLab/Gongfeng Fetch Comments Flow
  4. Post Comment (Add) - GitHub
  5. Post Comment (Add) - GitLab/Gongfeng
  6. Update Comment - GitHub
  7. Resolve Comment - GitLab/Gongfeng Only
  8. HTTP Request Handling Detail
  9. Token Resolution Hierarchy
  10. Backend Detection Decision Tree
  11. Caching Strategy
  12. Multi-Backend URL Construction
  13. Error Recovery

---

## 🗂️ Source Code File

**code-review-minimal.el** (1125 lines)

Use the line numbers in HTTP_ENDPOINTS.md to navigate to specific functions.

### Major Sections:
- **Lines 1-46**: Header, dependencies
- **Lines 48-166**: Configuration & customization
- **Lines 167-373**: Backend detection and selection
- **Lines 375-455**: HTTP layer (core request handler)
- **Lines 486-587**: GitLab/Gongfeng backend implementation
- **Lines 665-791**: GitHub backend implementation
- **Lines 793-952**: Overlay rendering and input handling
- **Lines 954-1118**: Backend dispatch and public commands

---

## 🎯 Navigation Guide

### "I want to understand..."

**...the overall architecture**
→ Read: `REPOSITORY_SUMMARY.md` (sections: Key Features, Architectural Summary)

**...how HTTP requests work**
→ Read: `HTTP_ENDPOINTS.md` (sections: Core HTTP Functions, HTTP Request Entry Point)
→ Or: `ANALYSIS.md` (sections: Authentication & HTTP Handling, HTTP Request Flow)

**...how to add a new backend**
→ Read: `REPOSITORY_SUMMARY.md` (section: Entry Points for Integration)
→ Or: `ANALYSIS.md` (sections: Backend-Specific sections)

**...the GitHub integration**
→ Read: `HTTP_ENDPOINTS.md` (section: GitHub-Specific HTTP Calls)
→ Or: `API_FLOW.md` (sections: 2, 4, 6)

**...the GitLab/Gongfeng integration**
→ Read: `HTTP_ENDPOINTS.md` (section: GitLab/Gongfeng-Specific HTTP Calls)
→ Or: `API_FLOW.md` (sections: 3, 5, 7)

**...authentication and tokens**
→ Read: `HTTP_ENDPOINTS.md` (section: Token Management)
→ Or: `ANALYSIS.md` (section: Authentication & HTTP Handling)

**...caching behavior**
→ Read: `ANALYSIS.md` (section: Caching Mechanism)
→ Or: `API_FLOW.md` (section: 11)

**...a specific function's location**
→ Use: `HTTP_ENDPOINTS.md` for functions containing "HTTP", token, auth
→ Or: Search `code-review-minimal.el` directly

---

## 🔍 Find What You Need

### By Topic

| Topic | Document | Section |
|-------|----------|---------|
| Architecture Overview | REPOSITORY_SUMMARY | Architectural Summary |
| HTTP Request Pattern | REPOSITORY_SUMMARY | HTTP Request Pattern |
| GitHub API Details | HTTP_ENDPOINTS | GitHub-Specific HTTP Calls |
| GitLab/Gongfeng API | HTTP_ENDPOINTS | GitLab/Gongfeng-Specific HTTP Calls |
| Authentication | ANALYSIS | Section 3 |
| Token Management | HTTP_ENDPOINTS | Token Management |
| Backend Detection | API_FLOW | Section 10 |
| Caching | ANALYSIS | Section 9 |
| Data Flow | API_FLOW | Section 1 |
| Error Handling | ANALYSIS | Section 12 |
| URL Parsing | ANALYSIS | Section 7 |
| Overlay Rendering | ANALYSIS | Section 13 |

### By File Section

| Code Lines | What's There | Find Details In |
|------------|-------------|-----------------|
| 1-46 | Header, deps | README.md, REPOSITORY_SUMMARY |
| 48-166 | Config | ANALYSIS Section 2 |
| 169-184 | Backend Detection | HTTP_ENDPOINTS, API_FLOW Section 10 |
| 186-245 | Caching | ANALYSIS Section 9 |
| 248-270 | Buffer State | ANALYSIS Section 11 |
| 274-306 | Tokens | HTTP_ENDPOINTS, API_FLOW Section 9 |
| 310-351 | Remote Parsing | HTTP_ENDPOINTS, ANALYSIS Section 7 |
| 375-455 | **HTTP Core** | HTTP_ENDPOINTS Section 1 |
| 386-399 | **Auth Headers** | HTTP_ENDPOINTS Section 2 |
| 401-427 | **HTTP Request** | HTTP_ENDPOINTS Section 1, API_FLOW Section 8 |
| 486-499 | GitLab Project Info | HTTP_ENDPOINTS Section: Project Info |
| 501-521 | Resolve MR ID | HTTP_ENDPOINTS |
| 525-548 | GitLab Fetch | API_FLOW Section 3 |
| 591-617 | GitLab Post | API_FLOW Section 5 |
| 667-682 | GitHub Project Info | HTTP_ENDPOINTS |
| 684-703 | GitHub Fetch | API_FLOW Section 2 |
| 724-763 | GitHub Post | API_FLOW Section 4 |
| 956-982 | Backend Dispatch | HTTP_ENDPOINTS |
| 1071-1118 | Minor Mode | API_FLOW Section 1 |

---

## 📊 Statistics

| Metric | Value |
|--------|-------|
| Total Documentation | 2,004 lines |
| Total Source Code | 1,125 lines |
| HTTP-Related Lines | ~80 lines |
| Supported Backends | 3 |
| HTTP Endpoints | ~13 |
| Public Commands | 8 |
| Internal Functions | 40+ |

---

## 🚀 Quick Start

1. **First time?** → Start with `REPOSITORY_SUMMARY.md`
2. **Want details?** → Read `ANALYSIS.md`
3. **Implementing features?** → Use `HTTP_ENDPOINTS.md`
4. **Debugging flow?** → Check `API_FLOW.md`
5. **Need line numbers?** → Reference `HTTP_ENDPOINTS.md`

---

## 🔧 Development Reference

### Finding HTTP Calls
```
Use: HTTP_ENDPOINTS.md
Search for endpoint name or method (GET, POST, PUT, PATCH)
```

### Adding New Backend
```
See: REPOSITORY_SUMMARY.md → Entry Points for Integration
Implement: 5 functions per backend
Update: 4 dispatch functions + backend detection
```

### Understanding Request Flow
```
Start: code-review-minimal--http-request (Line 401)
See: HTTP_ENDPOINTS.md Section 1
Details: ANALYSIS.md Section 3 & Section 5
Flows: API_FLOW.md Sections 2-8
```

### Token & Auth Issues
```
Reference: HTTP_ENDPOINTS.md Section: Token Management
Details: ANALYSIS.md Section 3
```

### API Integration Changes
```
Main function: code-review-minimal--api-url (Line 377)
Backend URLs: Line 87, 93, 99
Tokens: Line 66, 73, 80
```

---

## 📝 Notes

- **Line numbers** refer to `code-review-minimal.el`
- **All HTTP calls** go through `code-review-minimal--http-request`
- **All backends** follow same dispatch pattern (GitHub, GitLab, Gongfeng)
- **No external dependencies** - only Emacs built-ins
- **Async pattern** - no blocking HTTP calls

---

## Document Versions

All documentation generated on **2026-04-16** from `code-review-minimal.el` v0.2.0

