# Plan: AI Agent Student Navigation Links (Deep Links)

## Goal
Make the AI agent return direct, clickable links for students (find assignments by type/topic, open specific assignments, view submissions/results) so students don't have to manually navigate. Agent needs precise frontend route knowledge and context to generate correct links.

## Current State Analysis

### Frontend Routes (Student)
From router and pages:
- `/student/assignments` - list all assignments
- `/student/assignments/:id` - assignment detail
- `/student/assignments/:id?submit=1` - assignment detail with submit modal open
- `/student/practice` - practice assignments list  
- `/practice/:id` - practice assignment detail
- `/student/submissions` - my submissions list
- `/student/submissions/:submissionId/results` - submission results
- `/student/classes/:classId/assignments/:assignmentId/results` - lecturer view of results (context varies)
- Also results can be viewed from submissions page

### Backend APIs Available to Student Agent
From DomainToolConfiguration:
- `listMySubmissions` - GET /api/v1/submissions (submission-service), params: page,size,search
- `listMyTestPlans` - GET /api/v1/student/assignments/{assignmentId}/plans
- `getMyClassScores` - GET /api/v1/student/classes/{classId}/my-scores
- `getMyClass` - GET /api/v1/student/classes/{classId}
- `getClassRoster` - GET /api/v1/student/classes/{classId}/students

Also need to check if there are tools to:
- List student's assignments (there might be get/list assignments for student)
- Get assignment details
- Get results by submission/assignment

From course-service client in ai-assistant: has methods to get student assignments? Let us look up.

### AI Assistant Service
- Uses DomainApiTool to call backend services
- Agent has system prompt/tools configured
- Needs to know frontend base URL/routes to generate links

## Requirements
1. Student asks: "Xem bài tập nào dạng HTTP_REQUEST?" or "Tìm bài tập topic X" → agent finds matching assignments via available tools, returns clickable links like `[Bài tập ABC](/student/assignments/uuid)`
2. Student selects one → agent gives direct link to open in new tab
3. Student wants to see submissions for assignment → link to `/student/submissions?assignmentId=...` or direct submission
4. Student wants to see result of a submission → link to `/student/submissions/{submissionId}/results`
5. Works for practice assignments too (`/practice/{id}`)
6. Agent must have precise frontend route/context in its system prompt/instructions
7. Need to extend agent capabilities if missing tools (e.g., list student assignments)

## Design

### 1) Frontend Route Knowledge
Create a reference document or embed in agent config:
```json
{
  "studentRoutes": {
    "assignmentsList": "/student/assignments",
    "assignmentDetail": "/student/assignments/{assignmentId}",
    "assignmentDetailSubmit": "/student/assignments/{assignmentId}?submit=1",
    "practiceList": "/student/practice", 
    "practiceDetail": "/practice/{assignmentId}",
    "submissionsList": "/student/submissions",
    "submissionResults": "/student/submissions/{submissionId}/results"
  }
}
```

### 2) Missing Tools for Student Agent
Current student tools don't include:
- List student's assignments (course-service has student assignment endpoints)
- Get assignment by id
- Get student's assignment results (we just added FE endpoint calling result-service GET /api/v1/results/student/assignment/{assignmentId})

Need to add tools:
- `listMyAssignments` - GET /api/v1/student/assignments (course-service) with filters
- `getMyAssignment` - GET /api/v1/student/assignments/{assignmentId}
- `getMyAssignmentResults` - GET /api/v1/results/student/assignment/{assignmentId} (result-service)

Check if course-service has these endpoints accessible to students.

### 3) Agent System Prompt Enhancement
Update ai-assistant-service configuration to include:
- Frontend base URL (config)
- Route templates
- Instructions: "When student asks to find/view assignments/submissions/results, always return clickable markdown links using the exact routes. Prefer opening in new context - links should be absolute or relative as appropriate for the app."
- Link formatting rules

### 4) Link Generation Logic
Agent should:
- When listing assignments: return table with title, topic, type, link
- When user says "xem bai tap co dang HTTP_REQUEST" → search through assignments' test plans/steps? Or filter by topic/type
- Need to fetch assignment details with plans to inspect step types

But agent needs tools to inspect plans/steps - `listMyTestPlans` exists. Also need to get assignment list first.

### 5) Implementation Areas

**Backend (ai-assistant-service):**
- Add student tools for listing/getting assignments
- Add tool for getting assignment results
- Update system prompt with route knowledge
- Add configuration for frontend URL/routes
- Maybe add a helper/tool to generate links

**Frontend (ai-chat):**
- Ensure links in markdown open in new tab (`target="_blank" rel="noopener noreferrer"`) - check AssistantMessage rendering
- Links should work with React Router? Or just use <a> tags

Check AssistantMessage.tsx - uses ReactMarkdown, links will render as <a> by default. Need to ensure they open in new tab for external-like navigation or same app? Better to add target="_blank" for these deep links.

Also need to check if ReactMarkdown is configured with custom link renderer.

### 6) Configuration
Add to ai-assistant-service application.yml/config:
```yaml
app:
  frontend:
    base-url: ${FRONTEND_BASE_URL:http://localhost:5173}
    routes:
      student-assignments: /student/assignments
      ...
```

## Implementation Plan

### Phase 1: Discover Missing APIs/Tools
1. Check course-service student assignment controller endpoints
2. Check result-service for student assignment results endpoint (we saw it exists)
3. Identify what tools student agent currently has vs what we need

### Phase 2: Add Backend Tools
1. Add `listMyAssignments` tool pointing to course-service GET /api/v1/student/assignments
2. Add `getMyAssignment` tool for single assignment
3. Add `getMyAssignmentResults` tool for result-service
4. Add `getSubmissionResults` / ensure `listMySubmissions` gives enough info to build result links
5. Update DomainToolConfiguration

### Phase 3: Enhance Agent Context/Prompt
1. Add route knowledge to system prompt
2. Add instructions for link generation
3. Add frontend URL config
4. Update agent configuration

### Phase 4: Frontend Link Handling
1. Update AssistantMessage to make links open appropriately (target="_blank" for deep links)
2. Test link rendering

### Phase 5: Testing & Documentation
1. Test scenarios: find assignments by type, get submission links, get result links
2. Update skills/docs if needed

## Files to Modify

**ai-assistant-service:**
- `config/DomainToolConfiguration.java` - add tools
- `config/AgentConfiguration.java` or system prompt config
- `application.yml` / config files
- Possibly add route/link helper

**frontend-src:**
- `features/ai-chat/components/AssistantMessage.tsx` - link rendering
- Maybe add CSS for links

**config-services (if needed):**
- Update values for ai-assistant-service

## Risks & Considerations
- Agent needs to know when to use which tool
- Route patterns must match exactly
- Some assignments might be practice vs graded (different routes)
- Need to handle both cases
- Links should be user-friendly
- Don't expose internal IDs in confusing ways
- Security: links only for resources student can access (backend enforces)

## Success Criteria
- Student can ask "Tìm bài tập có step dạng HTTP_REQUEST" and get clickable links
- Student can ask "Xem bài nộp gần nhất của tôi" and get link to submission/result
- Links open in new tab and navigate correctly
- Agent uses correct routes for practice vs graded assignments
- Works across different query patterns
