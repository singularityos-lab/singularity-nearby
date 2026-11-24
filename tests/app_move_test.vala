using Singularity.Nearby;

const string APP = "dev.sinty.MoveTest";

[DBus (name = "dev.sinty.Migration1")]
public class FakeApp : Object {
    public Variant state;
    public Variant? restored = null;
    public int restores = 0;
    public int releases = 0;
    public string[] differences = {};

    public bool available { get { return true; } }

    public FakeApp(string text, string[] files) {
        var windows = new VariantBuilder(new VariantType("a(svvi)"));
        var widgets = new VariantBuilder(new VariantType("a{sa{sv}}"));
        var props = new VariantBuilder(new VariantType("a{sv}"));
        props.add("{sv}", "text", new Variant.string(text));
        widgets.add("{s@a{sv}}", "/", props.end());
        windows.add("(svvi)", "editor", new Variant.string("~/Documents/plan.txt"), widgets.end(), -1);
        state = new Variant("(usv@as@a(svvi))", 1, APP, new Variant.string("model"), new Variant.strv(files), windows.end());
    }

    public Variant capture() throws DBusError, IOError {
        return state;
    }

    public string[] restore(Variant incoming) throws DBusError, IOError {
        restores++;
        restored = incoming;
        return differences;
    }

    public void release() throws DBusError, IOError {
        releases++;
    }
}

class Side {
    public UserConfig config;
    public DBusConnection bus;
    public string home;
    public AppMove move;
    public FakeApp app;
    public Gee.HashMap<string, Device> peers = new Gee.HashMap<string, Device>();
    public Gee.ArrayList<string> results = new Gee.ArrayList<string>();
    public DBusConnection? decoy = null;
}

class MemoryPayload : Object, MovePayload {
    public Side from;
    public bool tamper = false;
    public Gee.HashMap<string, Bytes> stash = new Gee.HashMap<string, Bytes>();

    public MemoryPayload(Side from) {
        this.from = from;
    }

    public async void serve(Device d, Packet p, Bytes data, Cancellable? cancellable) throws Error {
        p.payload_port = 1;
        stash[p.get_string("transfer", "")] = data;
        deliver(from, d, p);
    }

    public async Bytes fetch(Device d, Packet p, int64 limit, Cancellable? cancellable) throws Error {
        var source = sides[d.id];
        var payload = payloads[source.config.device_id];
        var data = payload.stash[p.get_string("transfer", "")];
        if (data == null) throw new IOError.NOT_FOUND("no payload");
        if (!payload.tamper) return data;
        uint8[] copy = data.get_data();
        copy[copy.length / 2] ^= 0x40;
        return new Bytes(copy);
    }
}

Gee.HashMap<string, Side> sides;
Gee.HashMap<string, MemoryPayload> payloads;
Side laptop;
Side studio;
Side stranger;
int failures = 0;

void check(bool ok, string what) {
    print("%s %s\n", ok ? "ok" : "not ok", what);
    if (!ok) failures++;
}

void deliver(Side from, Device to_device, Packet p) {
    var to = sides[to_device.id];
    var seen_as = to.peers[from.config.device_id];
    if (seen_as == null) return;
    try {
        var copy = Packet.parse(p.serialize());
        copy.payload_size = p.payload_size;
        copy.payload_port = p.payload_port;
        Idle.add(() => {
            to.move.handle(seen_as, copy);
            return Source.REMOVE;
        });
    } catch (Error e) {
        error(e.message);
    }
}

string spawn_bus(string dir) {
    try {
        string printed;
        Process.spawn_sync(dir, { "dbus-daemon", "--session", "--fork", "--print-address=1" }, null,
            SpawnFlags.SEARCH_PATH, null, out printed, null, null);
        return printed.strip();
    } catch (Error e) {
        error(e.message);
    }
}

DBusConnection connect_bus(string address) {
    try {
        return new DBusConnection.for_address_sync(address,
            DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION, null, null);
    } catch (Error e) {
        error(e.message);
    }
}

Side make_side(string root, string name, string text, string[] files, bool shared_name = false) {
    var s = new Side();
    string dir = Path.build_filename(root, name);
    s.home = Path.build_filename(dir, "home");
    DirUtils.create_with_parents(Path.build_filename(s.home, "Documents"), 0700);
    s.config = new UserConfig(Path.build_filename(dir, "nearby"));
    try {
        s.config.load();
    } catch (Error e) {
        error(e.message);
    }
    string address = spawn_bus(dir);
    s.bus = connect_bus(address);
    s.app = new FakeApp(text, files);
    var app_bus = connect_bus(address);
    try {
        app_bus.register_object(AppMove.object_path(APP), s.app);
        if (shared_name) {
            var other = connect_bus(address);
            other.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                new Variant("(su)", APP, 4), null, DBusCallFlags.NONE, -1, null);
            s.decoy = other;
        }
        app_bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant("(su)", shared_name ? AppMove.alias(APP) : APP, 4), null, DBusCallFlags.NONE, -1, null);
    } catch (Error e) {
        error(e.message);
    }
    var payload = new MemoryPayload(s);
    payloads[s.config.device_id] = payload;
    s.move = new AppMove((d, p) => deliver(s, d, p), (d) => true, payload, s.bus, s.config, s.home);
    s.move.finished.connect((tid, ok, message) => s.results.add("%s %s".printf(ok ? "ok" : "failed", message)));
    sides[s.config.device_id] = s;
    return s;
}

void pair(Side a, Side b) {
    var d = new Device(b.config.device_id);
    d.name = b.config.device_name;
    d.record = new DeviceRecord(b.config.device_id);
    d.record.certificate = b.config.certificate_pem;
    d.pair_state = PairState.PAIRED;
    d.incoming = { AppMove.OFFER, AppMove.RESULT };
    a.peers[b.config.device_id] = d;
}

void see_unpaired(Side a, Side b) {
    var d = new Device(b.config.device_id);
    d.name = b.config.device_name;
    d.record = new DeviceRecord(b.config.device_id);
    d.record.certificate = b.config.certificate_pem;
    d.pair_state = PairState.NONE;
    d.incoming = { AppMove.OFFER, AppMove.RESULT };
    a.peers[b.config.device_id] = d;
}

void spin(int ms) {
    var loop = new MainLoop();
    Timeout.add(ms, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
}

void wait_for(owned SourceFunc done, int seconds = 10) {
    var loop = new MainLoop();
    int64 deadline = get_monotonic_time() + seconds * TimeSpan.SECOND;
    Timeout.add(10, () => {
        if (done() || get_monotonic_time() > deadline) {
            loop.quit();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    });
    loop.run();
}

string? run_move(Side from, Side to) {
    string? failure = null;
    bool done = false;
    from.move.move.begin(from.peers[to.config.device_id], Uuid.string_random(), APP, (o, r) => {
        try {
            from.move.move.end(r);
        } catch (Error e) {
            failure = e.message;
        }
        done = true;
    });
    wait_for(() => done, 20);
    if (!done) return "timed out";
    return failure;
}

string read_file(string path) {
    string text;
    try {
        FileUtils.get_contents(path, out text);
    } catch (Error e) {
        return "<missing>";
    }
    return text;
}

void write_file(string path, string text) {
    try {
        DirUtils.create_with_parents(Path.get_dirname(path), 0700);
        FileUtils.set_contents(path, text);
    } catch (Error e) {
        error(e.message);
    }
}

int count_files(string dir) {
    int n = 0;
    try {
        var d = Dir.open(dir);
        while (d.read_name() != null) n++;
    } catch (Error e) {
    }
    return n;
}

void offer_raw(Side from, Side to, string transfer, Bytes sealed) {
    bool done = false;
    from.move.offer.begin(from.peers[to.config.device_id], transfer, APP, sealed, (o, r) => {
        try {
            from.move.offer.end(r);
        } catch (Error e) {
        }
        done = true;
    });
    wait_for(() => done, 10);
}

Bytes seal_bundle(Side from, Side to, string transfer, int64 stamp, Variant files) {
    var bundle = new Variant("(usv@a(sayay))", AppMove.VERSION, APP, from.app.state, files);
    try {
        return NearbyEnvelope.seal(from.config.private_key_pem, to.config.certificate_pem,
            AppMove.context(from.config.device_id, to.config.device_id, transfer, APP), stamp, bundle.get_normal_form().get_data_as_bytes());
    } catch (Error e) {
        error(e.message);
    }
}

Variant one_file(string portable, string text) {
    var sum = new Checksum(ChecksumType.SHA256);
    sum.update(text.data, text.length);
    uint8[] digest = new uint8[32];
    size_t len = 32;
    sum.get_digest(digest, ref len);
    var files = new VariantBuilder(new VariantType("a(sayay)"));
    files.add("(s@ay@ay)", portable, new Variant.from_bytes(new VariantType("ay"), new Bytes(digest), true),
        new Variant.from_bytes(new VariantType("ay"), new Bytes(text.data), true));
    return files.end();
}

void reset() {
    foreach (var s in sides.values) {
        s.app.restored = null;
        s.app.restores = 0;
        s.app.releases = 0;
        s.app.differences = {};
        s.results.clear();
        payloads[s.config.device_id].tamper = false;
    }
}

int main(string[] args) {
    Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
    string root;
    try {
        root = DirUtils.make_tmp("app-move-XXXXXX");
    } catch (Error e) {
        error(e.message);
    }
    string apps = Path.build_filename(root, "share", "applications");
    write_file(Path.build_filename(apps, APP + ".desktop"), "[Desktop Entry]\nType=Application\nName=Move Test\nExec=true\n");
    Environment.set_variable("XDG_DATA_DIRS", Path.build_filename(root, "share"), true);
    sides = new Gee.HashMap<string, Side>();
    payloads = new Gee.HashMap<string, MemoryPayload>();
    laptop = make_side(root, "laptop", "Top secret plan, unsaved line", { "~/Documents/plan.txt" });
    studio = make_side(root, "studio", "", {});
    stranger = make_side(root, "stranger", "", {});
    pair(laptop, studio);
    pair(studio, laptop);
    pair(stranger, studio);
    see_unpaired(studio, stranger);

    check(AppMove.home_relative("~/Documents/plan.txt") == "Documents/plan.txt", "a document in home keeps its place");
    string[] refused = { "~/Documents/../../etc/passwd", "~/../x", "~/./x", "~//x", "~/", "~", "/etc/passwd", "Documents/x", "~user/x", "~/a/..", "" };
    bool all_refused = true;
    foreach (string bad in refused) {
        if (AppMove.home_relative(bad) != null) {
            print("# accepted %s\n", bad);
            all_refused = false;
        }
    }
    check(all_refused, "document paths outside home, absolute or with dot parts are refused");

    write_file(Path.build_filename(laptop.home, "Documents", "plan.txt"), "saved plan on the laptop\n");
    write_file(Path.build_filename(studio.home, "Documents", "plan.txt"), "older plan on the studio\n");

    reset();
    studio.app.differences = { "/editor: missing" };
    string? failure = run_move(laptop, studio);
    check(failure != null, "a move fails when the receiver cannot rebuild the app exactly");
    check(laptop.app.releases == 0, "the source app stays open when the receiver fails");
    check(read_file(Path.build_filename(studio.home, "Documents", "plan.txt")) == "older plan on the studio\n"
        && count_files(Path.build_filename(studio.home, "Documents")) == 1, "the receiver puts its own document back after a failure");

    reset();
    failure = run_move(laptop, studio);
    check(failure == null, "a paired device takes the app (%s)".printf(failure ?? "no error"));
    check(studio.app.restored != null && studio.app.restored.equal(laptop.app.state), "the receiver rebuilds the exact state it was sent");
    check(laptop.app.releases == 1, "the source app closes only after the receiver confirmed");
    check(read_file(Path.build_filename(studio.home, "Documents", "plan.txt")) == "saved plan on the laptop\n", "the document arrives with the app");
    bool kept = false;
    try {
        var d = Dir.open(Path.build_filename(studio.home, "Documents"));
        string? name;
        while ((name = d.read_name()) != null) {
            if (name.has_prefix("plan (kept before") && read_file(Path.build_filename(studio.home, "Documents", name)) == "older plan on the studio\n") kept = true;
        }
    } catch (Error e) {
    }
    check(kept, "the document already on the receiver is kept under another name");

    reset();
    payloads[laptop.config.device_id].tamper = true;
    failure = run_move(laptop, studio);
    check(failure != null && studio.app.restores == 0, "a package changed on the way is refused");
    check(laptop.app.releases == 0, "the source app stays open when the package was changed");

    reset();
    var sealed = seal_bundle(laptop, studio, "replay-transfer-0001", get_real_time() / TimeSpan.SECOND, one_file("~/Documents/plan.txt", "x"));
    offer_raw(laptop, studio, "replay-transfer-0001", sealed);
    int first = studio.app.restores;
    offer_raw(laptop, studio, "replay-transfer-0001", sealed);
    check(first == 1 && studio.app.restores == 1, "the same package cannot be played twice");

    reset();
    sealed = seal_bundle(laptop, studio, "stale-transfer-00001", get_real_time() / TimeSpan.SECOND - AppMove.FRESHNESS - 60, one_file("~/Documents/plan.txt", "x"));
    offer_raw(laptop, studio, "stale-transfer-00001", sealed);
    check(studio.app.restores == 0, "a package sealed too long ago is refused");

    reset();
    string outside = Path.build_filename(root, "studio", "escaped.txt");
    sealed = seal_bundle(laptop, studio, "escape-transfer-0001", get_real_time() / TimeSpan.SECOND, one_file("~/Documents/../../escaped.txt", "owned"));
    offer_raw(laptop, studio, "escape-transfer-0001", sealed);
    check(studio.app.restores == 0 && !FileUtils.test(outside, FileTest.EXISTS), "a document path that climbs out of home is refused");

    reset();
    sealed = seal_bundle(laptop, studio, "absolute-transfer-01", get_real_time() / TimeSpan.SECOND, one_file(outside, "owned"));
    offer_raw(laptop, studio, "absolute-transfer-01", sealed);
    check(studio.app.restores == 0 && !FileUtils.test(outside, FileTest.EXISTS), "an absolute document path is refused");

    reset();
    try {
        FileUtils.symlink(Path.build_filename(root, "studio"), Path.build_filename(studio.home, "Link"));
    } catch (Error e) {
        error(e.message);
    }
    sealed = seal_bundle(laptop, studio, "symlink-transfer-001", get_real_time() / TimeSpan.SECOND, one_file("~/Link/escaped.txt", "owned"));
    offer_raw(laptop, studio, "symlink-transfer-001", sealed);
    check(studio.app.restores == 0 && !FileUtils.test(outside, FileTest.EXISTS), "a document path through a link out of home is refused");

    reset();
    var files = new VariantBuilder(new VariantType("a(sayay)"));
    var good = one_file("~/Documents/forged.txt", "real");
    var entry = good.get_child_value(0);
    files.add("(s@ay@ay)", "~/Documents/forged.txt", entry.get_child_value(1),
        new Variant.from_bytes(new VariantType("ay"), new Bytes("fake".data), true));
    sealed = seal_bundle(laptop, studio, "digest-transfer-0001", get_real_time() / TimeSpan.SECOND, files.end());
    offer_raw(laptop, studio, "digest-transfer-0001", sealed);
    check(studio.app.restores == 0 && !FileUtils.test(Path.build_filename(studio.home, "Documents", "forged.txt"), FileTest.EXISTS),
        "a document that does not match its checksum is refused");

    reset();
    stranger.app.state = laptop.app.state;
    write_file(Path.build_filename(stranger.home, "Documents", "plan.txt"), "stranger\n");
    failure = run_move(stranger, studio);
    check(studio.app.restores == 0 && stranger.app.releases == 0, "a device that is not paired cannot send an app");

    reset();
    pair(studio, stranger);
    sealed = seal_bundle(laptop, studio, "relayed-transfer-001", get_real_time() / TimeSpan.SECOND, one_file("~/Documents/plan.txt", "x"));
    offer_raw(stranger, studio, "relayed-transfer-001", sealed);
    check(studio.app.restores == 0, "a package sealed by one device and sent by another is refused");

    reset();
    sealed = seal_bundle(laptop, stranger, "redirect-transfer-01", get_real_time() / TimeSpan.SECOND, one_file("~/Documents/plan.txt", "x"));
    offer_raw(laptop, studio, "redirect-transfer-01", sealed);
    check(studio.app.restores == 0, "a package sealed for another device is refused");

    reset();
    pair(laptop, stranger);
    studio.app.differences = { "/editor: missing" };
    ulong forger = laptop.move.progress.connect((tid, done, total) => {
        var forged = new Packet(AppMove.RESULT).set_string("transfer", tid).set_bool("ok", true);
        laptop.move.handle(laptop.peers[stranger.config.device_id], forged);
    });
    failure = run_move(laptop, studio);
    laptop.move.disconnect(forger);
    check(failure != null && laptop.app.releases == 0, "only the receiving device can confirm a move");

    var phone = make_side(root, "phone", "Note typed on the phone", {}, true);
    var tablet = make_side(root, "tablet", "", {}, true);
    pair(phone, tablet);
    pair(tablet, phone);
    reset();
    failure = run_move(phone, tablet);
    check(failure == null, "an app whose id is owned by another process moves through its migration name (%s)".printf(failure ?? "no error"));
    check(tablet.app.restored != null && tablet.app.restored.equal(phone.app.state), "the app behind the migration name receives the state");
    check(phone.app.releases == 1, "the app behind the migration name is released after the move");

    print(failures == 0 ? "all ok\n" : "%d failures\n".printf(failures));
    return failures == 0 ? 0 : 1;
}
