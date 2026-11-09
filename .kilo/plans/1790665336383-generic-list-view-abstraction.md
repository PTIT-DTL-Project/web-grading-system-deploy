# Plan: Client-side column sorting for list tables

## 1. Goal

Add client-side sorting to every column in the class list table. Sorting happens
in the FE only; the backend continues to return the current page unsorted (or with
its default `createdAt DESC`). The user clicks a column header to cycle through
ascending / descending / none.

## 2. Current state (evidence)

| Layer | What exists today |
|---|---|
| Backend | `ClassController` sorts with `Sort.by("createdAt").descending()` |
| Frontend hook | `useList` returns `rows` for the current page only (server-paginated) |
| Frontend table | `ListPage` renders antd `Table` with `standardPagination`; columns are defined in `ClassesPage` with no `sorter` |
| Frontend columns | `ClassesPage` defines columns: `name`, `semester`, `status`, `createdAt`, `actions` — no sort indicators, no sort handlers |

## 3. Design constraints

- **Client-side only**: do NOT send `sort` / `order` to the backend.
- **Server-paginated context**: `useList` only fetches one page at a time. Client-side
  sorting therefore operates on the **currently loaded page** only (default 20 rows).
  This is documented in the UI and skill notes. If full-dataset sorting is needed later,
  the page size must be increased or the backend must expose an unsorted/all-rows mode.
- **Default sort**: keep the backend's default `createdAt DESC` for the initial load.
  After the first user click, sorting is entirely client-side.
- **Column eligibility**: `actions` column is NOT sortable. All data columns are.

## 4. Proposed implementation

### 4.1 `ListPage` sort state

`ListPage` owns optional sort state. It does NOT impose sorting on every table;
pages opt in by passing `sortField` / `sortOrder` / `onSortChange`.

```tsx
interface ListPageProps<T, F extends ListFilters> {
  // ... existing props ...
  sortField?: keyof T
  sortOrder?: 'ascend' | 'descend'
  onSortChange?: (field: keyof T, order: 'ascend' | 'descend' | null) => void
}
```

`ListPage` behavior:
- Adds local state `sortField` and `sortOrder`, initialized from props.
- Adds a `useMemo` that produces `sortedRows` from `rows` + current sort state.
- Passes a combined `handleTableChange` to antd `Table` `onChange` that:
  - Updates `sortField` / `sortOrder` from the sorter event
  - Calls `onSortChange` if provided
  - Resets page to `0` when sort changes (fresh page with new sort)
- Passes `sortedRows` to `Table` instead of `rows`.

### 4.2 Local sort comparator

`ListPage` uses a default comparator for primitive values:

```tsx
const defaultComparator = <T,>(field: keyof T, order: 'ascend' | 'descend') => {
  return (a: T, b: T) => {
    const aVal = a[field]
    const bVal = b[field]
    if (aVal === bVal) return 0
    const isAsc = order === 'ascend'
    if (aVal == null) return isAsc ? -1 : 1
    if (bVal == null) return isAsc ? 1 : -1
    if (typeof aVal === 'string' && typeof bVal === 'string') {
      return isAsc ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal)
    }
    if (typeof aVal === 'number' && typeof bVal === 'number') {
      return isAsc ? aVal - bVal : bVal - aVal
    }
    return 0
  }
}
```

For columns that need custom comparison (e.g. `status` enum ordering, `createdAt` date parsing),
the page component passes a `columnSorter` map to `ListPage`:

```tsx
interface ColumnSorter<T> {
  [key: string]: (a: T, b: T) => number
}
```

`ListPageProps` gains:
```tsx
columnSorter?: ColumnSorter<T>
```

When present, `ListPage` uses `columnSorter[String(sortField)]` instead of the default
comparator for that field. If the field has no custom sorter, fall back to default.

### 4.3 `ClassesPage` wiring

`ClassesPage` defines sortable columns and passes sort state through:

```tsx
export function ClassesPage() {
  const [sortField, setSortField] = useState<keyof ClassResponse>('createdAt')
  const [sortOrder, setSortOrder] = useState<'ascend' | 'descend'>('descend')

  const columns: TableColumnsType<ClassResponse> = [
    {
      title: t('classes.name'),
      dataIndex: 'name',
      key: 'name',
      ellipsis: true,
      sorter: true,
      sortOrder: sortField === 'name' ? sortOrder : null,
    },
    {
      title: t('classes.semester'),
      dataIndex: 'semester',
      key: 'semester',
      width: 110,
      align: 'center',
      sorter: true,
      sortOrder: sortField === 'semester' ? sortOrder : null,
    },
    {
      title: t('classes.status'),
      dataIndex: 'status',
      key: 'status',
      width: 150,
      sorter: true,
      sortOrder: sortField === 'status' ? sortOrder : null,
      render: (status: ClassStatus) => ...
    },
    {
      title: t('classes.createdAt'),
      dataIndex: 'createdAt',
      key: 'createdAt',
      width: 180,
      sorter: true,
      sortOrder: sortField === 'createdAt' ? sortOrder : null,
      render: (createdAt: string | null) => formatDateTime(createdAt, i18n.language),
    },
    {
      title: t('common.actions'),
      key: 'actions',
      width: 170,
      align: 'right',
      // NO sorter — actions are not sortable
      render: ...
    },
  ]

  const columnSorter = {
    status: (a: ClassResponse, b: ClassResponse) => {
      const order = ['ACTIVE', 'ARCHIVED']
      return order.indexOf(a.status) - order.indexOf(b.status)
    },
  }

  return (
    <ListPage<ClassResponse, ClassesFilters>
      // ... existing props ...
      sortField={sortField}
      sortOrder={sortOrder}
      onSortChange={(field, order) => {
        setSortField(field)
        setSortOrder(order ?? 'ascend')
      }}
      columnSorter={columnSorter}
    />
  )
}
```

### 4.4 Default sort behavior

On first load, the backend returns rows sorted by `createdAt DESC`. `ListPage` initializes
`sortField` / `sortOrder` from props. If the parent passes `sortField='createdAt'` and
`sortOrder='descend'`, the local sort comparator reproduces the backend order.

When the user clicks a different column:
1. `ListPage` updates `sortField` / `sortOrder`
2. `onSortChange` notifies parent (`ClassesPage`)
3. `ListPage` resets page to `0`
4. `useMemo` re-sorts the current `rows` locally
5. Table re-renders with sorted data

When the user clicks the same column again:
- Cycle: `ascend` → `descend` → `null` (remove sort)
- On `null`, `ListPage` returns `rows` as-is (no sorting).

### 4.5 `useList` integration

No changes needed in `useList`. Sorting happens in `ListPage` after `rows` are fetched.
`useList` continues to return the page from the backend; `ListPage` sorts locally before
rendering.

### 4.6 URL persistence

Sort state is NOT persisted in the URL in v1. The skill documents this explicitly:
adding sort to URL query string is a follow-up.

## 5. Migration order

1. `ListPage.tsx` — add `sortField`, `sortOrder`, `onSortChange`, `columnSorter` props; add local sort state + `sortedRows` useMemo; wire Table `onChange`.
2. `StandardPagination.tsx` — no changes needed (page reset is handled by `ListPage` calling `setPage(0)`).
3. `ClassesPage.tsx` — add sort state, update columns with `sorter: true` + dynamic `sortOrder`, pass sort props to `ListPage`.
4. Verification: build, lint, i18n; manual sort clicks on each column show correct order.

## 6. What stays out of v1

- Full-dataset sorting (requires fetching all pages or backend unsorted mode)
- URL persistence of sort state
- Multi-column sort (shift-click)
- Persistent sort preference
- `showSizeChanger` (page size stays fixed)

## 7. Verification

- `npm run lint` 0/0
- `npm run build` exit 0
- Click each sortable column header: cycle `ascend` → `descend` → none
- `actions` column has no sort indicator
- Sort applies to current page only (20 rows)
- `status` column uses custom enum order `ACTIVE` → `ARCHIVED` when sorted
- `createdAt` strings sort correctly with default string comparator
- Changing page resets sort to default (`createdAt DESC` from backend)

## 8. Documentation updates (mandatory)

- **`.kilo/skills/react-frontend-antd/SKILL.md`** and **`.opencode/skills/react-frontend-antd/SKILL.md`**
  — add §21: "Client-side column sorting". Cover:
  - `ListPage` sort props (`sortField`, `sortOrder`, `onSortChange`, `columnSorter`)
  - Column config: `sorter: true` + `sortOrder: sortField === 'field' ? sortOrder : null`
  - Default comparator handles strings, numbers, nulls; custom comparators via `columnSorter`
  - Rule: with server-side pagination, sorting is page-local only
- **`docs/design/frontend-course-ui-plan.md`** — add a note under Phase 3:
  "Class list table: client-side column sorting added. Sort applies to current page only
  (server-paginated). Default sort on load: `createdAt DESC`."
