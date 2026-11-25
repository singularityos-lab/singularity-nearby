namespace Singularity.Nearby {

    public delegate InetAddress? CastAddress(Device d);

    public class AppCast : Object {
        public const string OFFER = "sinty.app.cast";
        public const string RESULT = "sinty.app.cast.result";
        public const int64 FRESHNESS = 300;
        private const int READY_TIMEOUT = 15;
        private const int ANSWER_TIMEOUT = 90;
        private const int SHOW_TIMEOUT = 30;
        private const int MAX_SIDE = 16384;

        private MoveSend send;
        private CastAddress address;
        private UserConfig config;
        private string binary;
        public string listen { get; set; default = ":0"; }
        private Gee.HashMap<string, Pending> waiting = new Gee.HashMap<string, Pending>();
        private Gee.HashMap<string, int64?> seen = new Gee.HashMap<string, int64?>();
        private Gee.HashSet<string> busy = new Gee.HashSet<string>();
        private Gee.HashMap<string, Helper> helpers = new Gee.HashMap<string, Helper>();

        public signal void started(string transfer, Device d, string app_id, bool incoming);
        public signal void finished(string transfer, bool ok, string message);

        private class Pending {
            public SourceFunc callback;
            public bool done = false;
            public bool parked = false;
            public bool ok = false;
            public string message = "";
            public string sealed = "";
            public Device device;

            public Pending(Device device, owned SourceFunc callback) {
                this.device = device;
                this.callback = (owned) callback;
            }
        }

        private class Helper {
            public Subprocess process;
            public DataInputStream events;
            public string device_id;
            public bool showing;
        }

        public AppCast(owned MoveSend send, owned CastAddress address, UserConfig config, string binary) {
            this.send = (owned) send;
            this.address = (owned) address;
            this.config = config;
            this.binary = binary;
        }

        public bool available {
            get { return FileUtils.test(binary, FileTest.IS_EXECUTABLE) && Environment.get_variable("WAYLAND_DISPLAY") != null; }
        }

        public string[] capabilities() {
            return available ? new string[] { OFFER, RESULT } : new string[] {};
        }

        public bool can_cast_to(Device d) {
            return available && d.paired && d.record != null && d.record.certificate != "" && OFFER in d.incoming && address(d) != null;
        }

        public static string context(string kind, string sender, string receiver, string transfer, string app_id) {
            return string.join("\n", kind, sender, receiver, transfer, app_id);
        }

        public bool shows(int pid) {
            foreach (var h in helpers.values) {
                if (h.showing && h.process.get_identifier() == pid.to_string()) return true;
            }
            return false;
        }

        public void close_shown(int pid) {
            foreach (var h in helpers.values) {
                if (h.showing && h.process.get_identifier() == pid.to_string()) h.process.send_signal(Posix.Signal.TERM);
            }
        }

        public void forget(Device d) {
            foreach (var entry in waiting.entries) {
                var pending = entry.value;
                if (pending.device != d || pending.done) continue;
                pending.done = true;
                pending.message = _("%s is no longer connected").printf(d.name);
                Idle.add(() => {
                    wake(pending);
                    return Source.REMOVE;
                });
            }
        }

        public void stop_all() {
            foreach (var h in helpers.values) h.process.send_signal(Posix.Signal.TERM);
        }

        private static string host_port(InetAddress addr, int port) {
            return addr.get_family() == SocketFamily.IPV6 ? "[%s]:%d".printf(addr.to_string(), port) : "%s:%d".printf(addr.to_string(), port);
        }

        private static Json.Object? parse(string text) {
            var parser = new Json.Parser();
            try {
                parser.load_from_data(text);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root();
            return root != null && root.get_node_type() == Json.NodeType.OBJECT ? root.get_object() : null;
        }

        private static string encode(Json.Builder b) {
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        private async Json.Object next_event(Helper h, int timeout) throws Error {
            var cancel = new Cancellable();
            uint timer = 0;
            timer = Timeout.add_seconds(timeout, () => {
                timer = 0;
                cancel.cancel();
                return Source.REMOVE;
            });
            try {
                while (true) {
                    string? line = yield h.events.read_line_async(Priority.DEFAULT, cancel, null);
                    if (line == null) throw new NearbyError.FAILED(_("The app stopped"));
                    var ev = parse(line);
                    if (ev == null || !ev.has_member("event")) continue;
                    if (ev.get_string_member("event") == "ended") {
                        string why = ev.has_member("error") ? ev.get_string_member("error") : _("The app stopped");
                        throw new NearbyError.FAILED(why);
                    }
                    return ev;
                }
            } catch (IOError.CANCELLED e) {
                throw new NearbyError.FAILED(_("The other device did not answer in time"));
            } finally {
                if (timer != 0) Source.remove(timer);
            }
        }

        private Helper spawn(string key, string device_id, string[] argv, bool input) throws Error {
            var flags = SubprocessFlags.STDOUT_PIPE | (input ? SubprocessFlags.STDIN_PIPE : SubprocessFlags.STDIN_INHERIT);
            var h = new Helper();
            h.process = new Subprocess.newv(argv, flags);
            h.events = new DataInputStream(h.process.get_stdout_pipe());
            h.device_id = device_id;
            helpers[key] = h;
            h.process.wait_async.begin(null, (o, r) => {
                try {
                    h.process.wait_async.end(r);
                } catch (Error e) {
                }
                if (helpers[key] == h) helpers.unset(key);
            });
            return h;
        }

        private async void drain(Helper h) {
            try {
                while ((yield h.events.read_line_async(Priority.DEFAULT, null, null)) != null) {
                }
            } catch (Error e) {
            }
        }

        private static void stop(Helper h) {
            h.process.send_signal(Posix.Signal.TERM);
        }

        public async void cast(Device d, string transfer, string app_id, int pid, string title) throws Error {
            if (!can_cast_to(d)) throw new NearbyError.FAILED(_("%s cannot show apps from this device").printf(d.name));
            if (!GLib.Application.id_is_valid(app_id)) throw new NearbyError.FAILED(_("This app cannot move"));
            if (waiting.has_key(transfer)) throw new NearbyError.FAILED(_("This move is already running"));
            started(transfer, d, app_id, false);
            Helper? h = null;
            try {
                h = spawn("out/" + transfer, d.id, { binary, "-cast-serve", "-app", app_id, "-pid", pid.to_string(), "-listen", listen }, true);
                var ready = yield next_event(h, READY_TIMEOUT);
                if (ready.get_string_member("event") != "ready") throw new NearbyError.FAILED(_("The app cannot be shown on another device"));
                var body = new Json.Builder();
                body.begin_object();
                body.set_member_name("port").add_int_value(ready.get_int_member("port"));
                body.set_member_name("key").add_string_value(ready.get_string_member("key"));
                body.set_member_name("width").add_int_value(ready.get_int_member("width"));
                body.set_member_name("height").add_int_value(ready.get_int_member("height"));
                body.set_member_name("title").add_string_value(title);
                body.end_object();
                var sealed = NearbyEnvelope.seal(config.private_key_pem, d.record.certificate,
                    context(OFFER, config.device_id, d.id, transfer, app_id), get_real_time() / TimeSpan.SECOND,
                    new Bytes(encode(body).data));
                string answer = yield offer(d, transfer, app_id, Base64.encode(sealed.get_data()));
                int64 stamp;
                var plain = NearbyEnvelope.open(config.private_key_pem, d.record.certificate,
                    context(RESULT, d.id, config.device_id, transfer, app_id), new Bytes(Base64.decode(answer)), out stamp);
                int64 now = get_real_time() / TimeSpan.SECOND;
                if (stamp < now - FRESHNESS || stamp > now + FRESHNESS) throw new NearbyError.FAILED(_("The answer came too late"));
                var reply = parse((string) plain.get_data());
                if (reply == null || !reply.has_member("key")) throw new NearbyError.FAILED(_("The other device answered something this device does not understand"));
                var trust = new Json.Builder();
                trust.begin_object();
                trust.set_member_name("cmd").add_string_value("trust");
                trust.set_member_name("screen").add_string_value(reply.get_string_member("key"));
                trust.end_object();
                var stdin = h.process.get_stdin_pipe();
                yield stdin.write_all_async((encode(trust) + "\n").data, Priority.DEFAULT, null, null);
                yield stdin.flush_async(Priority.DEFAULT, null);
                var showing = yield next_event(h, SHOW_TIMEOUT);
                if (showing.get_string_member("event") != "showing") throw new NearbyError.FAILED(_("The other device did not show the app"));
                h.showing = true;
                drain.begin(h);
                finished(transfer, true, "");
            } catch (Error e) {
                if (h != null) stop(h);
                finished(transfer, false, e.message);
                throw e;
            }
        }

        private async string offer(Device d, string transfer, string app_id, string sealed) throws Error {
            var pending = new Pending(d, offer.callback);
            waiting[transfer] = pending;
            uint timer = 0;
            timer = Timeout.add_seconds(ANSWER_TIMEOUT, () => {
                timer = 0;
                pending.done = true;
                pending.message = _("%s did not answer").printf(d.name);
                wake(pending);
                return Source.REMOVE;
            });
            try {
                send(d, new Packet(OFFER).set_string("transfer", transfer).set_string("app", app_id).set_string("sealed", sealed));
                if (!pending.done) {
                    pending.parked = true;
                    yield;
                }
            } finally {
                if (timer != 0) Source.remove(timer);
                waiting.unset(transfer);
            }
            if (!pending.ok) throw new NearbyError.FAILED(pending.message != "" ? pending.message : _("%s could not show the app").printf(d.name));
            return pending.sealed;
        }

        private static void wake(Pending pending) {
            if (!pending.parked) return;
            pending.parked = false;
            pending.callback();
        }

        private static bool valid_transfer(string transfer) {
            if (transfer.length < 16 || transfer.length > 64) return false;
            for (int i = 0; i < transfer.length; i++) {
                char c = transfer[i];
                if (!c.isalnum() && c != '-' && c != '_') return false;
            }
            return true;
        }

        private static string short_text(string text, int max) {
            string clean = text.make_valid().replace("\n", " ").strip();
            return clean.char_count() > max ? clean.substring(0, clean.index_of_nth_char(max)) : clean;
        }

        public void handle(Device d, Packet p) {
            if (!d.paired || d.record == null || d.record.certificate == "" || address(d) == null) return;
            string transfer = p.get_string("transfer", "") ?? "";
            if (p.packet_type == RESULT) {
                var pending = waiting[transfer];
                if (pending == null || pending.done || pending.device != d) return;
                pending.done = true;
                pending.ok = p.get_bool("ok", false);
                pending.message = short_text(p.get_string("message", "") ?? "", 200);
                pending.sealed = p.get_string("sealed", "") ?? "";
                wake(pending);
                return;
            }
            if (p.packet_type != OFFER) return;
            string app_id = p.get_string("app", "") ?? "";
            string sealed = p.get_string("sealed", "") ?? "";
            if (!valid_transfer(transfer) || !GLib.Application.id_is_valid(app_id) || sealed == "" || sealed.length > 8192) return;
            receive.begin(d, transfer, app_id, sealed);
        }

        private void answer(Device d, string transfer, bool ok, string message, string sealed) {
            var p = new Packet(RESULT).set_string("transfer", transfer).set_bool("ok", ok).set_string("message", message);
            if (sealed != "") p.set_string("sealed", sealed);
            send(d, p);
        }

        private bool seen_recently(string key) {
            int64 now = get_real_time() / TimeSpan.SECOND;
            var stale = new Gee.ArrayList<string>();
            foreach (var entry in seen.entries) {
                if (entry.value < now - FRESHNESS * 2) stale.add(entry.key);
            }
            foreach (string k in stale) seen.unset(k);
            return seen.has_key(key);
        }

        private async void receive(Device d, string transfer, string app_id, string sealed) {
            string key = d.id + "/" + transfer;
            if (busy.contains(key)) return;
            if (seen_recently(key)) {
                answer(d, transfer, false, _("This app was already received"), "");
                return;
            }
            busy.add(key);
            Helper? h = null;
            try {
                if (!available) throw new NearbyError.FAILED(_("This device cannot show apps from another device"));
                int64 stamp;
                var plain = NearbyEnvelope.open(config.private_key_pem, d.record.certificate,
                    context(OFFER, d.id, config.device_id, transfer, app_id), new Bytes(Base64.decode(sealed)), out stamp);
                int64 now = get_real_time() / TimeSpan.SECOND;
                if (stamp < now - FRESHNESS || stamp > now + FRESHNESS) throw new NearbyError.FAILED(_("The app was sent too long ago"));
                seen[key] = now;
                var body = parse((string) plain.get_data());
                if (body == null || !body.has_member("port") || !body.has_member("key")) throw new NearbyError.FAILED(_("The app arrived damaged"));
                int64 port = body.get_int_member("port");
                int64 width = body.has_member("width") ? body.get_int_member("width") : 0;
                int64 height = body.has_member("height") ? body.get_int_member("height") : 0;
                string cast_key = body.get_string_member("key");
                string title = short_text(body.has_member("title") ? body.get_string_member("title") : app_id, 120);
                if (port <= 0 || port > 65535 || width <= 0 || width > MAX_SIDE || height <= 0 || height > MAX_SIDE || Base64.decode(cast_key).length != 32)
                    throw new NearbyError.FAILED(_("The app arrived damaged"));
                var addr = address(d);
                if (addr == null) throw new NearbyError.FAILED(_("%s is no longer connected").printf(d.name));
                started(transfer, d, app_id, true);
                h = spawn("in/" + key, d.id, { binary, "-cast-show", "-core", host_port(addr, (int) port), "-cast-key", cast_key,
                    "-title", title, "-app", app_id, "-window-size", "%lldx%lld".printf(width, height), "-layout", SintyScreen.keyboard_layout() }, false);
                var id = yield next_event(h, READY_TIMEOUT);
                if (id.get_string_member("event") != "identity" || !id.has_member("key")) throw new NearbyError.FAILED(_("This device cannot show the app"));
                var reply = new Json.Builder();
                reply.begin_object();
                reply.set_member_name("key").add_string_value(id.get_string_member("key"));
                reply.end_object();
                var sealed_reply = NearbyEnvelope.seal(config.private_key_pem, d.record.certificate,
                    context(RESULT, config.device_id, d.id, transfer, app_id), get_real_time() / TimeSpan.SECOND, new Bytes(encode(reply).data));
                h.showing = true;
                drain.begin(h);
                answer(d, transfer, true, "", Base64.encode(sealed_reply.get_data()));
                finished(transfer, true, "");
            } catch (Error e) {
                if (h != null) stop(h);
                answer(d, transfer, false, e.message, "");
                finished(transfer, false, e.message);
            }
            busy.remove(key);
        }
    }
}
