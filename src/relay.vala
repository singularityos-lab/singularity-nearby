namespace Singularity.Nearby {

    public class RelayClient : Object {
        public const string ROOM_LABEL = "sinty-ai-room";
        public const int RETRY_MIN = 5;
        public const int RETRY_MAX = 300;
        public const size_t CHUNK = 65536;

        public string device_id { get; construct; }
        public string base_url { get; construct; }
        public string room { get; construct; }

        public signal void stream_ready(SocketConnection stream);

        private Soup.Session session = new Soup.Session();
        private Soup.WebsocketConnection? ws = null;
        private Socket? pump = null;
        private SocketSource? pump_source = null;
        private Cancellable cancel = new Cancellable();
        private uint retry_source = 0;
        private int retry = RETRY_MIN;
        private bool stopped = false;

        public RelayClient(string device_id, string base_url, string secret) {
            Object(device_id: device_id, base_url: base_url, room: room_id(secret));
        }

        public static string room_id(string secret) {
            var h = new Hmac(ChecksumType.SHA256, secret.data);
            h.update(ROOM_LABEL.data);
            return h.get_string();
        }

        public static string http_url(string url) {
            if (url.has_prefix("wss://")) return "https://" + url.substring(6);
            if (url.has_prefix("ws://")) return "http://" + url.substring(5);
            return url;
        }

        public void start() {
            connect_ws.begin();
        }

        public void stop() {
            stopped = true;
            cancel.cancel();
            if (retry_source != 0) Source.remove(retry_source);
            retry_source = 0;
            drop_stream();
            if (ws != null && ws.state == Soup.WebsocketState.OPEN) ws.close(1000, null);
            ws = null;
        }

        public async void push(string token, string kind) {
            if (token == "") return;
            var msg = new Soup.Message("POST", "%s/v1/push/%s".printf(http_url(base_url), room));
            if (msg == null) return;
            var body = new Json.Builder();
            body.begin_object();
            body.set_member_name("token");
            body.add_string_value(token);
            body.set_member_name("kind");
            body.add_string_value(kind);
            body.end_object();
            var gen = new Json.Generator();
            gen.set_root(body.get_root());
            msg.set_request_body_from_bytes("application/json", new Bytes(gen.to_data(null).data));
            try {
                yield session.send_and_read_async(msg, Priority.DEFAULT, cancel);
                if (msg.status_code != 204) warning("nearby: the relay refused the push: %u", msg.status_code);
            } catch (Error e) {
                warning("nearby: cannot reach the relay for a push: %s", e.message);
            }
        }

        private async void connect_ws() {
            if (stopped) return;
            var msg = new Soup.Message("GET", "%s/v1/room/%s?role=desktop".printf(base_url, room));
            if (msg == null) {
                warning("nearby: bad relay address %s", base_url);
                return;
            }
            try {
                ws = yield session.websocket_connect_async(msg, null, null, Priority.DEFAULT, cancel);
            } catch (Error e) {
                debug("nearby: relay unreachable: %s", e.message);
                schedule_retry();
                return;
            }
            retry = RETRY_MIN;
            ws.keepalive_interval = 30;
            ws.max_incoming_payload_size = 4 * 1024 * 1024;
            ws.message.connect(on_message);
            ws.closed.connect(() => {
                drop_stream();
                ws = null;
                schedule_retry();
            });
        }

        private void schedule_retry() {
            if (stopped || retry_source != 0) return;
            retry_source = Timeout.add_seconds(retry, () => {
                retry_source = 0;
                connect_ws.begin();
                return Source.REMOVE;
            });
            retry = int.min(retry * 2, RETRY_MAX);
        }

        private void on_message(int type, Bytes data) {
            if (type == Soup.WebsocketDataType.TEXT) {
                string text = ((string) data.get_data()).substring(0, (long) data.get_size());
                if (text == "peer") open_stream();
                else if (text == "gone") drop_stream();
                return;
            }
            if (pump == null) return;
            unowned uint8[] bytes = data.get_data();
            size_t done = 0;
            while (done < bytes.length) {
                try {
                    ssize_t n = pump.send(bytes[done:bytes.length]);
                    if (n <= 0) break;
                    done += n;
                } catch (Error e) {
                    drop_stream();
                    return;
                }
            }
        }

        private void open_stream() {
            drop_stream();
            int fds[2];
            if (Posix.socketpair(Posix.AF_UNIX, Posix.SOCK_STREAM, 0, fds) != 0) return;
            Socket other;
            try {
                pump = new Socket.from_fd(fds[0]);
                other = new Socket.from_fd(fds[1]);
            } catch (Error e) {
                Posix.close(fds[0]);
                Posix.close(fds[1]);
                pump = null;
                return;
            }
            pump.blocking = true;
            pump_source = pump.create_source(IOCondition.IN | IOCondition.HUP | IOCondition.ERR);
            pump_source.set_callback((s, cond) => {
                var buf = new uint8[CHUNK];
                ssize_t n = 0;
                try {
                    n = s.receive(buf);
                } catch (Error e) {
                    n = -1;
                }
                if (n <= 0) {
                    pump_source = null;
                    drop_stream();
                    return Source.REMOVE;
                }
                if (ws != null && ws.state == Soup.WebsocketState.OPEN) ws.send_binary(buf[0:n]);
                return Source.CONTINUE;
            });
            pump_source.attach(MainContext.default());
            stream_ready(SocketConnection.factory_create_connection(other));
        }

        private void drop_stream() {
            if (pump_source != null) pump_source.destroy();
            pump_source = null;
            if (pump != null) {
                try {
                    pump.close();
                } catch (Error e) {
                }
            }
            pump = null;
        }
    }
}
