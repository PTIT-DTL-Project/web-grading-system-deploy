# Plan: Cải thiện UI cấu hình Test Plan / Test Step cho giảng viên

## Mục tiêu
- Làm cho màn **Assignment Detail → Test Plan/Step** (StepEditor, TestPlanEditor, StepBuilderForm, HttpStepForm, DbStepForm) trực quan, ít sai sót hơn khi cấu hình JSON.
- Đồng bộ UI với validation backend mới: **connection bắt buộc** cho DB steps, `auto_inject_headers` chỉ áp dụng cho bước sau, `any_of` không chứa `status`, schema theo từng `stepType`.
- Giảm thời gian cấu hình, phát hiện lỗi sớm (realtime), giúp giảng viên hiểu quy tắc thay vì đọc tài liệu.

## Phạm vi
- Frontend: `frontend-src/web-grading-system-fe/src/features/assignments/*` (StepEditor, TestPlanEditor, StepBuilderForm, HttpStepForm, DbStepForm, ConnectionFields, SchemaPreview, stepBuilder.ts, stepConfig.ts)
- API: tận dụng `GET /api/v1/internal/assignments/{id}/config-schema?type=`, `POST /api/v1/internal/test-plans/validate-step`, `GET /api/v1/internal/test-plans/capabilities`
- i18n: `src/locales/vi.json`, `src/locales/en.json`

## Ưu tiên thực thi

### P0 - Ngăn lỗi nghiêm trọng (bắt buộc)
1. **Làm nổi bật connection bắt buộc cho DB steps**
   - Thêm banner "Bắt buộc" cho block connection, đánh dấu `database/username/password` là required rõ ràng
   - Tooltip giải thích: "Cần thiết để sandbox reset DB giữa các plan"
   - Validate trước khi save: highlight tab/section nếu thiếu
2. **Cảnh báo auto_inject_headers placement**
   - Nếu đặt `auto_inject_headers` ở step đầu tiên của plan → cảnh báo
   - Nếu step name/path gợi ý bước âm tính (401/403) và có auto_inject → cảnh báo "Bước kiểm tra âm tính nên tự đặt headers (shield)"
   - Thêm helper text ngắn
3. **Realtime validation qua API**
   - Thêm hook `useStepValidation` gọi `validate-step` (debounce 500ms)
   - Hiển thị lỗi theo path từ backend
   - Chặn save nếu validation fail

### P1 - Cải thiện trải nghiệm chính
4. **Assertions Builder**
   - UI builder thay thế JSON thô, động theo kind
   - Chặn thêm `status` vào `any_of`
   - Preview JSON config
5. **Biến có sẵn (available variables)**
   - Hiển thị `${var}` từ bước trước, click để chèn
   - Highlight biến chưa định nghĩa
6. **Schema-driven hints**
   - Dùng schema để hint/required

### P2 - Nâng cao
7. **Dry-run nhanh**
   - Nút "Thử chạy cấu hình" trong editor
8. **data[] builder cải tiến**
   - Preview số lần chạy, validate keys
9. **UX polish** - i18n, jump to error tab

## Thiết kế chi tiết

### A. Connection enforcement
**Files:** `DbStepForm.tsx`, `ConnectionFields.tsx`, `stepBuilder.ts`
- Required rules cho `dbName/dbUser/dbPassword`
- Alert giải thích bắt buộc
- Presets

### B. Realtime validation
**Files:** `StepEditor.tsx`, new `hooks/useStepValidation.ts`, `shared/api/endpoints/testPlans.ts`
```typescript
// validateStep(stepType, config) -> POST /api/v1/internal/test-plans/validate-step
```

### C. Assertions Builder
**Files:** new `components/AssertionsBuilder.tsx`, `HttpStepForm.tsx`

### D. Available variables
**Files:** `StepEditor.tsx`, `TestPlanEditor.tsx`

### E. auto_inject warnings
**Files:** `HttpStepForm.tsx`, `StepEditor.tsx`

## API usage
- `getConfigSchema(assignmentId, type?)` 
- `validateStep(stepType, config)`
- `capabilities()` optional

## Thứ tự triển khai
1. P0.1 Connection enforcement + warnings
2. P0.2 Realtime validation
3. P1.1 Assertions Builder
4. P1.2 Available variables
5. P2 Polish + dry-run

## Testing
- DB step thiếu credentials → block save + hiển thị lỗi
- any_of chứa status → builder chặn
- auto_inject ở bước âm tính → warning
- Realtime validation hiển thị lỗi backend
- Schema preview đúng theo stepType

## Definition of Done
- [ ] Connection bắt buộc rõ ràng
- [ ] auto_inject có warnings
- [ ] Realtime validation hoạt động
- [ ] Assertions builder dùng được
- [ ] Available variables panel
- [ ] i18n vi/en
- [ ] Không break flow hiện tại
- [ ] Typecheck pass
