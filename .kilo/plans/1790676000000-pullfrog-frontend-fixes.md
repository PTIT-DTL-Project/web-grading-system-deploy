# Plan: Fix remaining Pullfrog review findings (frontend)

## Context

All 14 files exist. No modules are missing. The 16 open threads from Pullfrog reviews 5350909006 and 5350951065 collapse into these distinct bugs:

| # | File | Issue | Lines |
|---|------|-------|-------|
| 1 | `tokens.ts` | Invalid 7-digit hex `'#F0F02F0'` — all borders dropped | :21 |
| 2 | `FilterBar.tsx` | Hardcoded "Lọc" / "Xóa lọc" Vietnamese on action buttons | :154-158 |
| 3 | `ListPage.tsx` | Raw `error.message` exposed in `ErrorState` title | :142 |
| 4 | `ListPage.tsx` | Raw `error.message` exposed in `Alert` banner title | :162 |
| 5 | `useList.ts` | `[filters]` effect resets applied filters + page on every parent render | :126-140 |
| 6 | `en.json` | Duplicate `classes.*` keys at lines 55-57 silently override lines 35-37 | :35-37, :55-57 |
| 7 | `vi.json` | Same duplicate-key pattern as en.json | :35-37, :55-57 |
| 8 | `StudentsTab.tsx` | Static `message.success/error` calls (violates AntdApp rule) | :47, :51 |
| 9 | `ScoreComponentsTab.tsx` | Static `message.warning/success/error` calls (5 locations) | :55, :60, :95, :101, :104 |
| 10 | `StudentScoreDrawer.tsx` | Static `message.success/error` calls (2 locations) | :64, :68 |

---

## Tasks

### 1. Fix invalid hex in `tokens.ts`

**File:** `src/shared/theme/tokens.ts:21`

Change `'#F0F02F0'` → `'#F0F0F0'`. This is a single-character fix that restores all `1px solid ${colors.border}` declarations across AppLayout and ClassDetailPage.

### 2. i18n the FilterBar action buttons

**File:** `src/shared/ui/FilterBar.tsx:154-158`

Replace hardcoded Vietnamese with i18n lookups. The keys already exist in both locales:
- `t('common.filter')` for "Lọc"
- `t('common.clearFilters')` for "Xóa lọc"

Add `useTranslation` import and `const { t } = useTranslation()` at the top of the component.

### 3. Use `useApiErrorMessage` in ListPage ErrorState

**File:** `src/shared/ui/ListPage.tsx:142`

Import `useApiErrorMessage` from `../api/errors` (already imported in other files), call it in the component, and replace:
```tsx
message={error instanceof Error ? error.message : String(error)}
```
with:
```tsx
message={toMessage(error)}
```

### 4. Use `useApiErrorMessage` in ListPage Alert banner

**File:** `src/shared/ui/ListPage.tsx:162`

Same fix as #3, for the `Alert` banner title:
```tsx
title={toMessage(error)}
```

### 5. Fix `useList.ts` filter reset on parent render

**File:** `src/shared/hooks/useList.ts:126-140`

The `[filters]` effect at line 135 fires on every parent render because `filters` is a new object reference each time. The `isInitialMount` guard only skips the first mount.

Fix: add a ref that tracks whether the effect has already synced, and only sync when `filters` actually changes after mount. Or simpler: compare `filters` against `localFilters` before syncing.

```tsx
useEffect(() => {
  if (isInitialMount.current) {
    isInitialMount.current = false
    return
  }
  // Only sync if the incoming filters are actually different from what we have
  setLocalFilters((prev) => {
    if (JSON.stringify(prev) === JSON.stringify(filters)) return prev
    return filters
  })
  setSubmittedFilters(filters)
  setSubmitVersion((v) => v + 1)
  setPage(0)
}, [filters])
```

Wait — `JSON.stringify` comparison in a setState callback is not ideal because `filters` may contain functions. Better: use a ref to track the previous filters identity and compare with `Object.is` or a shallow comparison.

Actually the cleanest fix: the effect should only fire when `filters` changes *identity* from the previous value. Since `ClassesPage` passes `{ filters: initialFilters }` where `initialFilters` is a stable object, the issue is that `useList` destructures `filters` from the params object which is recreated on every render.

Fix: in `useList`, accept `initialFilters` as a stable ref and only sync when it changes:

```tsx
const prevFiltersRef = useRef<F>(filters)
useEffect(() => {
  if (isInitialMount.current) {
    isInitialMount.current = false
    prevFiltersRef.current = filters
    return
  }
  if (shallowEquals(prevFiltersRef.current, filters)) return
  prevFiltersRef.current = filters
  setLocalFilters(filters)
  setSubmittedFilters(filters)
  setSubmitVersion((v) => v + 1)
  setPage(0)
}, [filters])
```

Where `shallowEquals` compares all own properties. This prevents the reset on unrelated parent re-renders while still syncing when the actual filter config changes.

### 6. Remove duplicate keys from `en.json`

**File:** `src/locales/en.json`

Lines 35-37 define `classes.namePlaceholder`, `classes.semester`, `classes.semesterPlaceholder`.
Lines 55-57 redefine the same three keys.

The values at lines 55-57 are the ones actually used (`"Class name..."`, `"Semester"`, `"e.g. 2025.1..."`). Remove lines 35-37 (the overridden originals) and keep lines 55-57. Then shift the `components` block up so there's no gap.

### 7. Remove duplicate keys from `vi.json`

**File:** `src/locales/vi.json`

Same fix as #6. Remove the overridden originals at lines 35-37, keep the active values at lines 55-57.

### 8. Convert `StudentsTab.tsx` to `App.useApp()`

**File:** `src/features/classes/tabs/StudentsTab.tsx`

Replace `import { ..., message } from 'antd'` with `import { App } from 'antd'` and `const { message } = App.useApp()`.

Change `message.success(...)` and `message.error(...)` to use the context-aware `message`.

### 9. Convert `ScoreComponentsTab.tsx` to `App.useApp()`

**File:** `src/features/classes/tabs/ScoreComponentsTab.tsx`

Same pattern as #8. Replace static `message` import with `App.useApp()`. Update all 5 call sites.

### 10. Convert `StudentScoreDrawer.tsx` to `App.useApp()`

**File:** `src/features/classes/tabs/StudentScoreDrawer.tsx`

Same pattern. Replace static `message` with `App.useApp()`. Update 2 call sites.

---

## Order of execution

Cheapest wins first:
1. `tokens.ts` — one character
2. `en.json` / `vi.json` — delete 6 lines total
3. `FilterBar.tsx` — add `useTranslation`, swap 2 strings
4. `ListPage.tsx` — add `useApiErrorMessage`, swap 2 expressions
5. `useList.ts` — add shallow-compare guard
6. `StudentsTab.tsx` — convert to `App.useApp()`
7. `ScoreComponentsTab.tsx` — convert to `App.useApp()`
8. `StudentScoreDrawer.tsx` — convert to `App.useApp()`

## Out of scope

- The 16 threads also include items from the first Pullfrog review about build failures from missing modules — those files now exist, so those threads are resolved.
- `AppLayout.tsx` comment mismatch (lines 113-117) — cosmetic, not blocking.
- `ClassesPage.tsx` inline hex colors for status badges — cosmetic, separate from the border token fix.
- `StudentClassesPage.tsx` ComingSoon placeholder — intentional, not a bug.
- Backend authorization architecture (`X-User-Id` is client-asserted) — product decision.
