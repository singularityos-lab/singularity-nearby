namespace Singularity.Nearby {

    public delegate void MoveSend(Device d, Packet p);
    public delegate bool MoveRoute(Device d);

    public interface MovePayload : Object {
        public abstract async void serve(Device d, Packet p, Bytes data, Cancellable? cancellable) throws Error;
        public abstract async Bytes fetch(Device d, Packet p, int64 limit, Cancellable? cancellable) throws Error;
    }

    public class AppMove : Object {
        public const string OFFER = "sinty.app.move";
        public const string RESULT = "sinty.app.move.result";
        public const uint32 VERSION = 1;
        public const int64 MAX_BUNDLE = 256 * 1024 * 1024;
        public const int64 FRESHNESS = 300;
        public const string INTERFACE = "dev.sinty.Migration1";
        private const string BUNDLE_TYPE = "(usva(sayay))";
        private const int RESULT_TIMEOUT = 180;
        private const int START_TIMEOUT = 20;

        private MoveSend send;
        private MoveRoute route;
        private MovePayload payload;
        private DBusConnection bus;
        private UserConfig config;
        private string home;
        private Gee.HashMap<string, Pending> waiting = new Gee.HashMap<string, Pending>();
        private Gee.HashMap<string, int64?> seen = new Gee.HashMap<string, int64?>();
        private Gee.HashSet<string> busy = new Gee.HashSet<string>();

        public signal void started(string transfer, Device d, string app_id, bool incoming);
        public signal void progress(string transfer, int64 done, int64 total);
        public signal void finished(string transfer, bool ok, string message);
        public signal void arrived(Device d, string app_id);

        private class Pending {
            public SourceFunc callback;
            public bool done = false;
            public bool parked = false;
            public bool ok = false;
            public string message = "";
            public Device device;

            public Pending(Device device, owned SourceFunc callback) {
                this.device = device;
                this.callback = (owned) callback;
            }
        }

        private class Placed {
            public File target;
            public File? kept = null;
            public bool written = false;
        }

        public AppMove(owned MoveSend send, owned MoveRoute route, MovePayload payload, DBusConnection bus, UserConfig config, string home) {
            this.send = (owned) send;
            this.route = (owned) route;
            this.payload = payload;
            this.bus = bus;
            this.config = config;
            this.home = home;
        }

        public string[] capabilities() {
            return { OFFER, RESULT };
        }

        public bool can_move_to(Device d) {
            return d.paired && d.record != null && d.record.certificate != "" && OFFER in d.incoming && route(d);
        }

        public static string object_path(string app_id) {
            return "/" + app_id.replace(".", "/").replace("-", "_");
        }

        public static string context(string sender, string receiver, string transfer, string app_id) {
            return string.join("\n", OFFER, sender, receiver, transfer, app_id);
        }

        public static string alias(string app_id) {
            return app_id + ".Migration";
        }

        private async bool has_owner(string name) {
            try {
                var reply = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                    new Variant("(s)", name), new VariantType("(b)"), DBusCallFlags.NONE, 2000, null);
                return reply.get_child_value(0).get_boolean();
            } catch (Error e) {
                return false;
            }
        }

        private async bool exports(string name, string app_id) {
            try {
                yield bus.call(name, object_path(app_id), "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", INTERFACE), new VariantType("(a{sv})"), DBusCallFlags.NO_AUTO_START, 2000, null);
                return true;
            } catch (Error e) {
                return false;
            }
        }

        public async string address(string app_id) {
            string a = alias(app_id);
            if (yield has_owner(a)) return a;
            return app_id;
        }

        public async bool supports(string app_id) {
            if (!GLib.Application.id_is_valid(app_id)) return false;
            try {
                string target = yield address(app_id);
                var reply = yield bus.call(target, object_path(app_id), "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", INTERFACE, "Available"), new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, 2000, null);
                return reply.get_child_value(0).get_variant().get_boolean();
            } catch (Error e) {
                return false;
            }
        }

        public async Bytes seal(Device d, string transfer, string app_id) throws Error {
            if (!GLib.Application.id_is_valid(app_id)) throw new NearbyError.FAILED(_("This app cannot move"));
            string target = yield address(app_id);
            var reply = yield bus.call(target, object_path(app_id), INTERFACE, "Capture", null,
                new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, 30000, null);
            var state = reply.get_child_value(0).get_variant();
            if (!state.is_of_type(new VariantType("(usvasa(svvi))"))) throw new NearbyError.FAILED(_("The app sent a state this device does not understand"));
            if (state.get_child_value(1).get_string() != app_id) throw new NearbyError.FAILED(_("The app sent the state of another app"));
            var files = new VariantBuilder(new VariantType("a(sayay)"));
            int64 total = 0;
            foreach (string portable in state.get_child_value(3).get_strv()) {
                string? relative = home_relative(portable);
                if (relative == null) throw new NearbyError.FAILED(_("%s is outside your home folder and cannot move").printf(portable));
                var file = File.new_for_path(Path.build_filename(home, relative));
                uint8[] contents;
                yield file.load_contents_async(null, out contents, null);
                total += contents.length;
                if (total > MAX_BUNDLE) throw new NearbyError.FAILED(_("The open documents are too large to move"));
                files.add("(s@ay@ay)", portable, bytes_variant(digest(contents)), bytes_variant(contents));
            }
            var bundle = new Variant("(usv@a(sayay))", VERSION, app_id, state, files.end());
            return NearbyEnvelope.seal(config.private_key_pem, d.record.certificate,
                context(config.device_id, d.id, transfer, app_id), get_real_time() / TimeSpan.SECOND, bundle.get_normal_form().get_data_as_bytes());
        }

        public async void move(Device d, string transfer, string app_id) throws Error {
            if (!can_move_to(d)) throw new NearbyError.FAILED(_("%s cannot take apps from this device").printf(d.name));
            if (waiting.has_key(transfer)) throw new NearbyError.FAILED(_("This move is already running"));
            started(transfer, d, app_id, false);
            try {
                var sealed = yield seal(d, transfer, app_id);
                yield offer(d, transfer, app_id, sealed);
                yield release(app_id);
                finished(transfer, true, "");
            } catch (Error e) {
                finished(transfer, false, e.message);
                throw e;
            }
        }

        public async void offer(Device d, string transfer, string app_id, Bytes sealed) throws Error {
            var p = new Packet(OFFER).set_string("transfer", transfer).set_string("app", app_id);
            p.payload_size = sealed.length;
            var pending = new Pending(d, offer.callback);
            waiting[transfer] = pending;
            uint timer = 0;
            try {
                yield payload.serve(d, p, sealed, null);
                progress(transfer, sealed.length, sealed.length);
                if (!pending.done) {
                    timer = Timeout.add_seconds(RESULT_TIMEOUT, () => {
                        timer = 0;
                        pending.done = true;
                        pending.message = _("%s did not answer").printf(d.name);
                        wake(pending);
                        return Source.REMOVE;
                    });
                    pending.parked = true;
                    yield;
                }
            } finally {
                if (timer != 0) Source.remove(timer);
                waiting.unset(transfer);
            }
            if (!pending.ok) throw new NearbyError.FAILED(pending.message != "" ? pending.message : _("%s could not open the app").printf(d.name));
        }

        private async void release(string app_id) {
            try {
                string target = yield address(app_id);
                yield bus.call(target, object_path(app_id), INTERFACE, "Release", null, null, DBusCallFlags.NO_AUTO_START, 10000, null);
            } catch (Error e) {
                warning("nearby: %s moved but did not close here: %s", app_id, e.message);
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

        public void handle(Device d, Packet p) {
            if (!d.paired || d.record == null || d.record.certificate == "" || !route(d)) return;
            if (p.packet_type == RESULT) {
                var pending = waiting[p.get_string("transfer", "")];
                if (pending == null || pending.done || pending.device != d) return;
                pending.done = true;
                pending.ok = p.get_bool("ok", false);
                pending.message = short_message(p.get_string("message", "") ?? "");
                wake(pending);
                return;
            }
            if (p.packet_type != OFFER) return;
            string transfer = p.get_string("transfer", "");
            string app_id = p.get_string("app", "");
            if (!valid_transfer(transfer) || !GLib.Application.id_is_valid(app_id) || !p.has_payload) return;
            receive.begin(d, p, transfer, app_id);
        }

        private static void wake(Pending pending) {
            if (!pending.parked) return;
            pending.parked = false;
            pending.callback();
        }

        private static string short_message(string text) {
            string clean = text.make_valid().replace("\n", " ").strip();
            return clean.char_count() > 200 ? clean.substring(0, clean.index_of_nth_char(200)) : clean;
        }

        private static bool valid_transfer(string transfer) {
            if (transfer.length < 16 || transfer.length > 64) return false;
            for (int i = 0; i < transfer.length; i++) {
                char c = transfer[i];
                if (!c.isalnum() && c != '-' && c != '_') return false;
            }
            return true;
        }

        private void answer(Device d, string transfer, bool ok, string message) {
            send(d, new Packet(RESULT).set_string("transfer", transfer).set_bool("ok", ok).set_string("message", message));
        }

        private async void receive(Device d, Packet p, string transfer, string app_id) {
            string key = d.id + "/" + transfer;
            if (busy.contains(key)) return;
            if (seen_recently(key)) {
                answer(d, transfer, false, _("This app was already received"));
                return;
            }
            busy.add(key);
            started(transfer, d, app_id, true);
            Gee.ArrayList<Placed>? placed = null;
            try {
                if (p.payload_size <= 0 || p.payload_size > MAX_BUNDLE + 4096) throw new NearbyError.FAILED(_("The app is too large to move"));
                var sealed = yield payload.fetch(d, p, p.payload_size, null);
                progress(transfer, sealed.length, sealed.length);
                int64 stamp;
                var plain = NearbyEnvelope.open(config.private_key_pem, d.record.certificate,
                    context(d.id, config.device_id, transfer, app_id), sealed, out stamp);
                int64 now = get_real_time() / TimeSpan.SECOND;
                if (stamp < now - FRESHNESS || stamp > now + FRESHNESS) throw new NearbyError.FAILED(_("The app was sent too long ago"));
                seen[key] = now;
                var bundle = new Variant.from_bytes(new VariantType(BUNDLE_TYPE), plain, false);
                if (!bundle.is_normal_form()) throw new NearbyError.FAILED(_("The app arrived damaged"));
                if (bundle.get_child_value(0).get_uint32() != VERSION) throw new NearbyError.FAILED(_("Update this device to receive apps from %s").printf(d.name));
                if (bundle.get_child_value(1).get_string() != app_id) throw new NearbyError.FAILED(_("The app arrived damaged"));
                if (new DesktopAppInfo(app_id + ".desktop") == null) throw new NearbyError.FAILED(_("This app is not installed here"));
                var state = bundle.get_child_value(2).get_variant();
                if (!state.is_of_type(new VariantType("(usvasa(svvi))")) || state.get_child_value(1).get_string() != app_id)
                    throw new NearbyError.FAILED(_("The app arrived damaged"));
                placed = yield place(bundle.get_child_value(3), d.name);
                yield restore(app_id, state);
                answer(d, transfer, true, "");
                finished(transfer, true, "");
                arrived(d, app_id);
                placed = null;
            } catch (Error e) {
                if (placed != null) undo(placed);
                answer(d, transfer, false, e.message);
                finished(transfer, false, e.message);
            }
            busy.remove(key);
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

        public static string? home_relative(string portable) {
            if (!portable.has_prefix("~/")) return null;
            string rest = portable.substring(2);
            if (rest == "" || rest.length > 4096) return null;
            foreach (string part in rest.split("/")) {
                if (part == "" || part == "." || part == "..") return null;
            }
            return rest;
        }

        private static uint8[] digest(uint8[] data) {
            var sum = new Checksum(ChecksumType.SHA256);
            sum.update(data, data.length);
            uint8[] result = new uint8[32];
            size_t len = result.length;
            sum.get_digest(result, ref len);
            return result;
        }

        private static Variant bytes_variant(uint8[] data) {
            return new Variant.from_bytes(new VariantType("ay"), new Bytes(data), true);
        }

        private static bool same_bytes(uint8[] a, uint8[] b) {
            return a.length == b.length && (a.length == 0 || Memory.cmp(a, b, a.length) == 0);
        }

        private async Gee.ArrayList<Placed> place(Variant files, string from) throws Error {
            var checked = new Gee.ArrayList<string>();
            for (size_t i = 0; i < files.n_children(); i++) {
                var entry = files.get_child_value(i);
                string? relative = home_relative(entry.get_child_value(0).get_string());
                if (relative == null || relative in checked) throw new NearbyError.FAILED(_("The app tried to write outside your home folder"));
                var data = entry.get_child_value(2).get_data_as_bytes().get_data();
                if (!same_bytes(digest(data), entry.get_child_value(1).get_data_as_bytes().get_data()))
                    throw new NearbyError.FAILED(_("A document arrived damaged"));
                checked.add(relative);
            }
            var placed = new Gee.ArrayList<Placed>();
            try {
                for (size_t i = 0; i < files.n_children(); i++) {
                    var entry = files.get_child_value(i);
                    var data = entry.get_child_value(2).get_data_as_bytes().get_data();
                    var target = File.new_for_path(Path.build_filename(home, checked[(int) i]));
                    yield ensure_inside(target);
                    var item = new Placed();
                    item.target = target;
                    placed.add(item);
                    FileInfo? info = null;
                    try {
                        info = yield target.query_info_async(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
                    } catch (IOError.NOT_FOUND e) {
                    }
                    if (info != null) {
                        if (info.get_file_type() != FileType.REGULAR) throw new NearbyError.FAILED(_("%s is not a document here").printf(target.get_basename()));
                        uint8[] existing;
                        yield target.load_contents_async(null, out existing, null);
                        if (same_bytes(existing, data)) continue;
                        item.kept = yield keep_copy(target, from);
                    }
                    yield target.replace_contents_async(data, null, false, FileCreateFlags.NONE, null, null);
                    item.written = true;
                }
            } catch (Error e) {
                undo(placed);
                throw e;
            }
            return placed;
        }

        private async void ensure_inside(File target) throws Error {
            var root = File.new_for_path(home);
            var dir = target.get_parent();
            var missing = new Gee.ArrayList<File>();
            while (dir != null && !dir.equal(root)) {
                FileInfo? info = null;
                try {
                    info = yield dir.query_info_async(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
                } catch (IOError.NOT_FOUND e) {
                }
                if (info == null) missing.insert(0, dir);
                else if (info.get_file_type() != FileType.DIRECTORY) throw new NearbyError.FAILED(_("The app tried to write outside your home folder"));
                dir = dir.get_parent();
            }
            if (dir == null) throw new NearbyError.FAILED(_("The app tried to write outside your home folder"));
            foreach (var m in missing) m.make_directory(null);
        }

        private async File keep_copy(File target, string from) throws Error {
            string name = target.get_basename();
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            string ext = dot > 0 ? name.substring(dot) : "";
            string when = new DateTime.now_local().format("%Y-%m-%d %H.%M.%S");
            for (int n = 1; n < 100; n++) {
                string label = n == 1 ? _("%s (kept before %s arrived, %s)").printf(stem, from, when)
                    : _("%s (kept before %s arrived, %s, %d)").printf(stem, from, when, n);
                var copy = target.get_parent().get_child(label + ext);
                if (copy.query_exists()) continue;
                target.move(copy, FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
                return copy;
            }
            throw new NearbyError.FAILED(_("Cannot keep the copy of %s that is already here").printf(name));
        }

        private void undo(Gee.ArrayList<Placed> placed) {
            for (int i = placed.size - 1; i >= 0; i--) {
                var item = placed[i];
                try {
                    if (item.written) item.target.delete(null);
                    if (item.kept != null) item.kept.move(item.target, FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
                } catch (Error e) {
                    warning("nearby: cannot put back %s: %s", item.target.get_path(), e.message);
                }
            }
        }

        private async void restore(string app_id, Variant state) throws Error {
            string target = yield address(app_id);
            if (!(yield exports(target, app_id))) {
                yield launch(app_id);
                target = yield address(app_id);
            }
            var reply = yield call_restore(target, app_id, state);
            string[] differences = reply.get_child_value(0).get_strv();
            if (differences.length > 0) {
                try {
                    yield bus.call(target, object_path(app_id), INTERFACE, "Release", null, null, DBusCallFlags.NO_AUTO_START, 10000, null);
                } catch (Error e) {
                }
                throw new NearbyError.FAILED(_("The app could not be rebuilt exactly here"));
            }
        }

        private async Variant call_restore(string target, string app_id, Variant state) throws Error {
            return yield bus.call(target, object_path(app_id), INTERFACE, "Restore", new Variant("(v)", state),
                new VariantType("(as)"), DBusCallFlags.NO_AUTO_START, 120000, null);
        }

        private async void launch(string app_id) throws Error {
            var info = new DesktopAppInfo(app_id + ".desktop");
            string? exe = info != null ? info.get_executable() : null;
            if (exe == null || Environment.find_program_in_path(exe) == null) throw new NearbyError.FAILED(_("This app is not installed here"));
            bool up = false;
            bool taken = yield has_owner(app_id);
            uint watch = 0;
            uint watch_alias = Bus.watch_name_on_connection(bus, alias(app_id), BusNameWatcherFlags.NONE, () => {
                if (up) return;
                up = true;
                launch.callback();
            }, null);
            if (!taken) watch = Bus.watch_name_on_connection(bus, app_id, BusNameWatcherFlags.NONE, () => {
                if (up) return;
                up = true;
                launch.callback();
            }, null);
            uint timer = 0;
            timer = Timeout.add_seconds(START_TIMEOUT, () => {
                timer = 0;
                launch.callback();
                return Source.REMOVE;
            });
            try {
                var launcher = new SubprocessLauncher(SubprocessFlags.NONE);
                launcher.spawnv({ Environment.find_program_in_path(exe), "--gapplication-service" });
                if (!up) yield;
            } finally {
                if (watch != 0) Bus.unwatch_name(watch);
                Bus.unwatch_name(watch_alias);
                if (timer != 0) Source.remove(timer);
            }
            if (!up) throw new NearbyError.FAILED(_("The app did not start here"));
        }
    }

    public class TlsMovePayload : Object, MovePayload {
        private UserConfig config;
        private SystemConfig system;

        public TlsMovePayload(UserConfig config, SystemConfig system) {
            this.config = config;
            this.system = system;
        }

        public async void serve(Device d, Packet p, Bytes data, Cancellable? cancellable) throws Error {
            if (d.link == null || d.record == null) throw new IOError.NOT_CONNECTED(_("%s is no longer connected").printf(d.name));
            var server = new PayloadServer(system);
            p.payload_port = server.port;
            d.link.send(p);
            yield server.serve(new MemoryInputStream.from_bytes(data), data.length, Tls.own_certificate(config), d.record.certificate, cancellable, null);
        }

        public async Bytes fetch(Device d, Packet p, int64 limit, Cancellable? cancellable) throws Error {
            if (d.link == null || d.record == null) throw new IOError.NOT_CONNECTED(_("%s is no longer connected").printf(d.name));
            if (p.payload_size < 0 || p.payload_size > limit) throw new IOError.MESSAGE_TOO_LARGE(_("The app is too large to move"));
            var tls = yield connect_payload(d.link.address, p.payload_port, Tls.own_certificate(config), d.record.certificate, cancellable);
            var buffer = new uint8[p.payload_size];
            try {
                size_t read;
                yield tls.input_stream.read_all_async(buffer, Priority.DEFAULT, cancellable, out read);
                if (read != buffer.length) throw new IOError.PARTIAL_INPUT(_("The app arrived incomplete"));
            } finally {
                try {
                    yield tls.close_async(Priority.DEFAULT, null);
                } catch (Error e) {
                }
            }
            return new Bytes.take((owned) buffer);
        }
    }
}
