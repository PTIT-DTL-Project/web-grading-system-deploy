# ArtifactService — executor-service

Nơi lưu: `docs/api/docs/executor-service/artifact-service.md`

Mục đích: giải thích cách tải submission zip từ RustFS, giải nén an toàn (chặn zip-slip),
phục hồi quyền thực thi cho wrapper Maven/Gradle, và vá `distributionUrl` của Maven wrapper.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.infra` |
| Annotation | `@Service`, `@RequiredArgsConstructor`, `@Slf4j` |
| Phụ thuộc | `MinioClient`, `RustFsProperties`, `ExecutorProperties` |
| Ai gọi | `GradingOrchestrator` ở giai đoạn `BUILDING` |

## 2. `fetchWorkDir(UUID submissionId, String rustfsPath)`

| Khía cạnh | Nội dung |
|---|---|
| Work dir | `executorProperties.tempDir()/<submissionId>` |
| Output | `Path` thư mục đã giải nén |
| Lỗi | `IllegalStateException(FAILED_FETCH_ARTIFACT + rustfsPath, cause)` khi IO lỗi |

### Luồng

1. `Files.createDirectories(workDir)`.
2. Tải object về `workDir/submission.zip` (`Constant.Artifact.SUBMISSION_ZIP`) qua
   `fetchObject`, ghi đè nếu đã có.
3. `unzip(zipFile, workDir)`.
4. `restoreWrapperPermissions(workDir)`.
5. `patchWrapperDistributionUrl(workDir)`.
6. Log `Submission artifact ready` và trả `workDir`.

## 3. `fetchObject(String rustfsPath)` — `protected`

`minioClient.getObject(bucket = rustFsProperties.bucketName(), object = rustfsPath)`.
Mọi exception bọc thành `IOException(FAILED_DOWNLOAD_OBJECT + path)`.

`protected` để test có thể override, không gọi MinIO thật.

## 4. `unzip(Path zipFile, Path destDir)` — `static`

1. Mở `ZipInputStream`.
2. Với từng entry: `target = destDir.resolve(entry.getName()).normalize()`.
3. Nếu `!target.startsWith(destDir.normalize())` → `IllegalArgumentException(ZIP_ESCAPE_PREFIX
   + name)`. Đây là chốt chặn **zip-slip** (`../` hoặc đường dẫn tuyệt đối).
4. Entry thư mục → `createDirectories`; entry file → tạo thư mục cha rồi `transferTo`.

## 5. `restoreWrapperPermissions(Path workDir)` — `static`

Zip giải nén làm mất mode bit Unix, nên `mvnw`/`gradlew` (755 trong git) thành không thực
thi, và `docker build` chết ở `RUN ./mvnw` với `Permission denied` (exit 126).

Hàm chỉ chmod `rwxr-xr-x` cho hai file `mvnw`, `gradlew` ở gốc workdir nếu là file thường và
chưa executable. Mọi lỗi chỉ log warn — chmod không được làm hỏng bài chấm; `docker build`
mới là cổng kiểm tra thật.

## 6. `patchWrapperDistributionUrl(Path workDir)` — package-private

Bối cảnh: artifact `maven-wrapper-distribution` chỉ chứa script + wrapper jar, **không có
binary Maven**; project trỏ `distributionUrl` vào đó sẽ fail build một cách hệ thống.

| Bước | Chi tiết |
|---|---|
| 1 | Lấy `executorProperties.maven().pinnedDistributionUrl()`; null/blank → `false` |
| 2 | File `.mvn/wrapper/maven-wrapper.properties` phải tồn tại, nếu không → `false` |
| 3 | Đọc dòng; nếu không dòng `distributionUrl=` nào chứa `maven-wrapper-distribution-` → `false` |
| 4 | Ghi lại: dòng `distributionUrl=` thay bằng URL pinned; dòng `distributionSha256Sum=` bị bỏ (checksum ghim URL cũ) |
| 5 | Log info, trả `true` |

Mọi lỗi đọc/ghi chỉ log debug, trả `false` — best-effort, không làm hỏng bài chấm. Chỉ URL
chứa `maven-wrapper-distribution-` bị sửa; URL Maven đầy đủ, Gradle, project không wrapper
đi qua nguyên trạng.

## 7. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| Zip chứa `../../etc/passwd` | `IllegalArgumentException` → job `FAILED` |
| Zip rỗng | Workdir rỗng, build sẽ fail ở bước sau |
| Object không tồn tại trên RustFS | `IOException` → `IllegalStateException` |
| `mvnw` đã executable | Bỏ qua, không chmod lại |
| Properties có BOM/CRLF | Đọc theo UTF-8, ghi lại theo UTF-8 — có thể đổi CRLF thành LF |

## 8. Liên kết

- `ExecutorProperties.tempDir()`, `.maven().pinnedDistributionUrl()` — cấu hình trong
  `application.yaml`.
- `GradingOrchestrator` dùng `workDir` làm build context cho compose — xem
  `grading-orchestrator.md`.