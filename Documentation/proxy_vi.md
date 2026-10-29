# Quy tắc proxy

bindhosts có thể chạy một proxy TLS cục bộ, chặn các yêu cầu tới những tên miền bạn
liệt kê và viết lại hoặc chặn chúng theo đường dẫn URL. Nó hoạt động độc lập với
quy tắc hosts: hosts quyết định chặn gì bằng `0.0.0.0`, proxy quyết định trả lời gì
tại máy.

## Bật

1. Chuyển sang chế độ xem **Proxy** trong trang quy tắc.
2. Bật công tắc cạnh tab.
3. Thêm ít nhất một tên miền và một quy tắc.
4. Nhấn nút action.

Lần bật đầu tiên sẽ tạo CA cục bộ tại `/data/adb/bindhosts/proxy/certs/` và cài vào
kho tin cậy của hệ thống. Khóa riêng không rời khỏi thiết bị và không nằm trong module.

## Khai báo tên miền

Proxy chỉ ký chứng chỉ cho những tên miền được báo trước. Thêm một dòng hosts vào
`proxy/custom.txt`:

```
127.0.0.1 api.example.com
```

Địa chỉ đó được ghi vào tệp hosts của hệ thống, nên yêu cầu tới tên miền sẽ đến
proxy cục bộ thay vì internet. Một dòng mỗi tên miền; CA có thể ký bao nhiêu cũng được.

## Quy tắc

Một quy tắc mỗi dòng. `<path>` được so với đường dẫn yêu cầu; dấu `*` ở cuối biến nó
thành khớp tiền tố.

```
mock    <path> [body]     trả lời tại máy bằng body
patch   <path> <json>     thay giá trị của khóa rồi chuyển tiếp
forward <path>            chuyển tiếp tới máy chủ thật
block   <path>            đóng kết nối
```

Ví dụ:

```
mock    /api/version {"code":0,"data":{"haveUpdate":false}}
patch   /api/* {"appVersion":"9.9.9"}
forward /api/*
block   /ads/*
```

`patch` chỉ thay giá trị của các khóa cùng tên, các byte còn lại của body giữ
nguyên — thứ tự trường, định dạng số và khoảng trắng đều được bảo toàn. Quy tắc
`patch` cũng chuyển tiếp, đừng thêm `forward` riêng cho cùng đường dẫn.

Quy tắc được xét theo thứ tự trong tệp, khớp đầu tiên sẽ thắng. Đường dẫn không có
quy tắc sẽ được chuyển tiếp.

## Bộ quy tắc

`proxy/sources.txt` nhận một URL mỗi dòng. Nội dung tải về được lưu đệm trong
`proxy/cache/` và dùng lại khi mọi lần tải đều thất bại, nên chạy ngoại tuyến vẫn
tạo ra bộ quy tắc gần nhất.

## Bộ quy tắc tải về là chỉ đọc

Các quy tắc lấy từ `sources.txt` được hợp nhất vào sản phẩm nhưng không thể sửa
trong WebUI. Trang truy vấn gắn thẻ `SRC` cho chúng và không có nút xóa. Để ngừng
dùng một quy tắc đã tải, hãy xóa URL của nó khỏi `sources.txt`.

Chế độ xem Hosts cũng không có nút trên các dòng `SRC`: không thể xóa quy tắc đã
tải khỏi trang truy vấn. Hãy xóa URL của nó khỏi `sources.txt`.

## Danh sách trắng và danh sách đen

Cả hai đều là chế độ xem của `proxy/custom.txt`:

- **Danh sách trắng** liệt kê các quy tắc `forward`
- **Danh sách đen** liệt kê các quy tắc `block`

Sửa cái nào cũng là sửa `proxy/custom.txt`. Chúng không phải tệp riêng.

## Tắt

Tắt proxy sẽ dừng daemon, giải phóng `127.0.0.1:443` và xóa các mục proxy khỏi tệp
hosts. Tệp quy tắc và CA được giữ lại, nên bật lại không cần cấu hình.

CA ở lại kho tin cậy cho đến lần khởi động lại tiếp theo. Không thể tháo gỡ khi đang
chạy vì điểm gắn nằm trong nhóm lan truyền dùng chung.

## Khắc phục sự cố

Xem `/data/adb/bindhosts/proxy.log`:

| Dòng | Ý nghĩa |
|---|---|
| `loaded N system roots` | Phải khác 0, nếu không yêu cầu tới máy chủ sẽ thất bại |
| `signed leaf for <tên miền>` | Đã cấp chứng chỉ cho tên miền đó |
| `drop <tên miền> (not in proxy rules)` | Một tên miền bị chặn đã đến proxy |
| `daemon exited ... (fail=x/10)` | Daemon chết liên tục; sau 10 lần khởi động ngắn proxy tự tắt |

Nếu proxy đang bật mà yêu cầu không bị chặn, hãy kiểm tra tên miền có dòng
`127.0.0.1` trong `proxy/custom.txt` hay không.
