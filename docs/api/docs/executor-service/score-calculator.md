# ScoreCalculator — executor-service

Nơi lưu: `docs/api/docs/executor-service/score-calculator.md`

Mục đích: giải thích công thức tính điểm theo trọng số của một plan, quy ước với bước
`SKIPPED`, và cách điểm plan được result-service tổng hợp lại.

---

## 1. Tổng quan

`ScoreCalculator` là utility `final` với constructor private — không phải bean, không có
trạng thái. Nó nhận danh sách điểm từng bước và trả về điểm của plan theo thang `maxScore`.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.scoring` |
| Loại | `public final class` + static method |
| Ai gọi | `GradingOrchestrator` sau khi chạy hết các bước của một plan |

## 2. Kiểu dữ liệu vào/ra

### 2.1 `record StepScore(boolean passed, boolean skipped, int weight)`

| Trường | Ý nghĩa |
|---|---|
| `passed` | Bước đạt mọi assertion |
| `skipped` | Bước bị bỏ qua do bước `required` trước đó thất bại |
| `weight` | Trọng số của bước trong plan (mặc định 1) |

### 2.2 `score(List<StepScore> steps, BigDecimal maxScore)`

Trả về `BigDecimal` scale 2, làm tròn `HALF_UP`.

## 3. Công thức

```text
totalWeight  = Σ weight (mọi bước, kể cả SKIPPED)
passedWeight = Σ weight của bước (không skipped) và passed

score = maxScore × passedWeight / totalWeight      (totalWeight > 0)
score = 0.00                                        (totalWeight == 0)
```

Điểm quan trọng: **bước `SKIPPED` vẫn nằm ở mẫu số nhưng không cộng vào tử số**, nên nó
kéo điểm xuống đúng như một bước không đạt. Quy ước này thay đổi so với bản cũ (loại
`SKIPPED` khỏi cả hai vế) theo yêu cầu nghiệp vụ: điểm bài nộp phải phản ánh việc có bước
không được chấm.

Ví dụ: 3 bước weight 1, 1, 2; bước 1 pass, bước 2 fail, bước 3 skipped; maxScore = 10.

```text
totalWeight  = 4
passedWeight = 1
score = 10 × 1 / 4 = 2.50
```

## 4. Trường hợp biên

| Tình huống | Kết quả |
|---|---|
| Không có bước nào (`totalWeight == 0`) | `0.00` |
| Tất cả bước `SKIPPED` | `0.00` |
| `maxScore` null | Ném `NullPointerException` tại `maxScore.multiply` — caller phải truyền thang điểm |
| Điểm lẻ | Làm tròn 2 chữ số `HALF_UP` |

Lỗi hạ tầng (compose không lên, timeout) không đi qua công thức này: orchestrator ép điểm
plan về 0 khi job `FAILED`.

## 5. Quan hệ với result-service

Công thức này phải khớp cách result-service tổng hợp `planSubtotals()`: kết quả plan gửi
sang result-service đã là điểm cuối của plan, result-service chỉ nhân trọng số plan và
cộng lại. Vì vậy đổi công thức ở đây bắt buộc rà lại `ResultService` bên result-service.