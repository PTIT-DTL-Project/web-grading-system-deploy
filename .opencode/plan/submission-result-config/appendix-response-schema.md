# Appendix — F1 AI response JSON contract (v1)

```json
{
  "title": "StudentExplanation", "type": "object",
  "required": ["assignmentId", "submissionId", "locale", "summary", "steps", "nextActions", "disclaimer"],
  "properties": {
    "assignmentId": {"type": "string"}, "submissionId": {"type": "string"},
    "locale": {"type": "string", "enum": ["vi", "en"]},
    "summary": {"type": "object",
      "required": ["scoreText", "passed", "failed", "skipped", "oneLiner"],
      "properties": {
        "scoreText": {"type": "string"},
        "passed": {"type": "integer", "minimum": 0},
        "failed": {"type": "integer", "minimum": 0},
        "skipped": {"type": "integer", "minimum": 0},
        "oneLiner": {"type": "string", "maxLength": 300}}},
    "steps": {"type": "array", "items": {"type": "object",
      "required": ["stepOrder", "stepName", "status", "whatAsked", "whatMissing", "howToFix"],
      "properties": {
        "stepOrder": {"type": "integer", "minimum": 1},
        "stepName": {"type": "string"},
        "status": {"type": "string", "enum": ["PASSED", "FAILED", "ERROR", "SKIPPED"]},
        "whatAsked": {"type": "string", "maxLength": 500},
        "whatMissing": {"type": "string", "maxLength": 500},
        "evidence": {"type": "object", "properties": {
          "expectedStatus": {"type": ["integer", "null"]},
          "actualStatus": {"type": ["integer", "null"]},
          "failedAssertionKinds": {"type": "array", "items": {"type": "string"}}}},
        "howToFix": {"type": "string", "maxLength": 500}}}},
    "nextActions": {"type": "array", "maxItems": 3, "items": {"type": "string", "maxLength": 200}},
    "disclaimer": {"type": "string", "const": "Giải thích tự động, không phải đáp án mẫu."}
  }
}
```
