using Singularity.Nearby;

public struct FakeScreen {
    public string id;
    public string name;
    public bool connected;
}

[DBus (name = "dev.sinty.Core1")]
public class FakeCore : Object {
    public Gee.ArrayList<string> ids = new Gee.ArrayList<string>();
    public Gee.ArrayList<string> names = new Gee.ArrayList<string>();
    public int admitted = 0;

    [DBus (name = "ID")]
    public string core_id { owned get { return "c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"; } }

    [DBus (name = "Name")]
    public string core_name { owned get { return "Living Room"; } }

    [DBus (name = "PublicKey")]
    public string public_key { owned get { return "S0VZ"; } }

    [DBus (name = "Screens")]
    public FakeScreen[] screens {
        owned get {
            FakeScreen[] out = {};
            for (int i = 0; i < ids.size; i++) {
                FakeScreen s = { ids[i], names[i], false };
                out += s;
            }
            return out;
        }
    }

    public void admit_screen(string id, string name) throws Error {
        admitted++;
        ids.add(id);
        names.add(name);
    }
}

const string SCREEN_ID = "5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c";

FakeCore core;
SintyScreen core_side;
SintyScreen viewer_side;
Device viewer_seen_by_core;
Device core_seen_by_viewer;
string log_path;
int core_asked = 0;
int viewer_asked = 0;
bool core_answers = true;
bool core_holds = false;
NotificationAction? held_answer = null;
string[] failures;

Device paired_device(string id, string name, string[] incoming) {
    var d = new Device(id);
    d.name = name;
    d.record = new DeviceRecord(id);
    d.pair_state = PairState.PAIRED;
    d.incoming = incoming;
    return d;
}

void relay(Device to_side, SintyScreen to, Packet p) {
    try {
        var copy = Packet.parse(p.serialize());
        Idle.add(() => {
            to.handle(to_side, copy);
            return false;
        });
    } catch (Error e) {
        error(e.message);
    }
}

void wait_until(owned SourceFunc done) {
    var loop = new MainLoop();
    int64 deadline = get_monotonic_time() + 5 * TimeSpan.SECOND;
    Timeout.add(10, () => {
        if (done() || get_monotonic_time() > deadline) {
            loop.quit();
            return false;
        }
        return true;
    });
    loop.run();
}

void settle() {
    var loop = new MainLoop();
    Timeout.add(300, () => {
        loop.quit();
        return false;
    });
    loop.run();
}

string calls() {
    string text;
    try {
        FileUtils.get_contents(log_path, out text);
    } catch (Error e) {
        return "";
    }
    return text;
}

void reset_log() {
    try {
        FileUtils.set_contents(log_path, "");
    } catch (Error e) {
        error(e.message);
    }
}

void test_a_screen_asks_once_then_is_remembered() {
    reset_log();
    viewer_side.show_from.begin(core_seen_by_viewer, (o, r) => {
        try {
            viewer_side.show_from.end(r);
        } catch (Error e) {
            error(e.message);
        }
    });
    wait_until(() => viewer_side.showing(core_seen_by_viewer));
    assert(viewer_side.showing(core_seen_by_viewer));
    assert(core_asked == 1);
    assert(core.admitted == 1);
    assert(core.ids[0] == SCREEN_ID && core.names[0] == "Laptop");
    string log = calls();
    assert("-core-id c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0 -core-name Living Room -core-key S0VZ" in log);
    assert("-window" in log && "-core 127.0.0.1:7412" in log && "-name Laptop" in log && "-layout us" in log);

    viewer_side.stop(core_seen_by_viewer);
    wait_until(() => !viewer_side.showing(core_seen_by_viewer));
    assert(!viewer_side.showing(core_seen_by_viewer));

    viewer_side.show_from.begin(core_seen_by_viewer);
    wait_until(() => viewer_side.showing(core_seen_by_viewer));
    assert(viewer_side.showing(core_seen_by_viewer));
    assert(core_asked == 1);
    viewer_side.stop(core_seen_by_viewer);
    wait_until(() => !viewer_side.showing(core_seen_by_viewer));
}

void test_the_core_offers_itself() {
    core.ids.clear();
    core.names.clear();
    core.admitted = 0;
    core_asked = 0;
    try {
        core_side.offer(viewer_seen_by_core);
    } catch (Error e) {
        error(e.message);
    }
    wait_until(() => viewer_side.showing(core_seen_by_viewer));
    assert(viewer_side.showing(core_seen_by_viewer));
    assert(viewer_asked == 1);
    assert(core_asked == 0);
    assert(core.admitted == 1);
    viewer_side.stop(core_seen_by_viewer);
    wait_until(() => !viewer_side.showing(core_seen_by_viewer));
}

void test_unasked_offers_and_forged_invites_do_nothing() {
    core.ids.clear();
    core.names.clear();
    core.admitted = 0;
    core_asked = 0;
    reset_log();
    var granted = new Packet(SintyScreen.OFFER).set_string("core-id", "c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0")
        .set_string("core-name", "Evil").set_string("core-key", "S0VZ").set_int("port", 7412);
    viewer_side.handle(core_seen_by_viewer, granted);
    settle();
    assert(!viewer_side.showing(core_seen_by_viewer));
    assert(calls() == "");

    core_answers = false;
    var forged = new Packet(SintyScreen.REQUEST).set_string("screen-id", SCREEN_ID)
        .set_string("screen-name", "Laptop").set_string("token", "guess");
    core_side.handle(viewer_seen_by_core, forged);
    settle();
    assert(core_asked == 1);
    assert(core.admitted == 0);
    core_answers = true;
}

void test_a_screen_waiting_for_consent_is_asked_about_once() {
    core.ids.clear();
    core.names.clear();
    core.admitted = 0;
    core_asked = 0;
    core_holds = true;
    var request = new Packet(SintyScreen.REQUEST).set_string("screen-id", SCREEN_ID)
        .set_string("screen-name", "Laptop").set_string("token", "").set_string("mode", SintyScreen.MODE_INPUT);
    core_side.handle(viewer_seen_by_core, request);
    core_side.handle(viewer_seen_by_core, request);
    settle();
    assert(core_asked == 1);
    assert(core.admitted == 0);

    held_answer("closed");
    core_side.handle(viewer_seen_by_core, request);
    settle();
    assert(core_asked == 2);

    held_answer("accept");
    held_answer("closed");
    wait_until(() => core.admitted == 1);
    assert(core.admitted == 1);
    core_holds = false;
    core_side.handle(viewer_seen_by_core, request);
    wait_until(() => core.admitted == 2);
    assert(core_asked == 2);
    assert(core.admitted == 2);
}

int main(string[] args) {
    Test.init(ref args);
    failures = {};
    string dir;
    try {
        dir = DirUtils.make_tmp("screen-XXXXXX");
    } catch (Error e) {
        error(e.message);
    }
    log_path = Path.build_filename(dir, "calls");
    string helper = Path.build_filename(dir, "sinty-screen");
    try {
        FileUtils.set_contents(helper, "#!/bin/sh\necho \"$*\" >> '%s'\ncase \" $* \" in *' -id '*) echo %s;; *' -window '*) exec sleep 30;; esac\n".printf(log_path, SCREEN_ID));
        FileUtils.chmod(helper, 0755);
    } catch (Error e) {
        error(e.message);
    }
    Environment.set_variable("WAYLAND_DISPLAY", "wayland-test", true);

    DBusConnection bus;
    try {
        bus = Bus.get_sync(BusType.SESSION);
        core = new FakeCore();
        bus.register_object("/dev/sinty/Core1", core);
    } catch (Error e) {
        error(e.message);
    }
    bool named = false;
    Bus.own_name_on_connection(bus, "dev.sinty.Core1", BusNameOwnerFlags.NONE, () => named = true, null);
    wait_until(() => named);

    viewer_seen_by_core = paired_device("1111", "Laptop", { SintyScreen.OFFER });
    core_seen_by_viewer = paired_device("2222", "Living Room", { SintyScreen.REQUEST });
    var loopback = new InetAddress.loopback(SocketFamily.IPV4);

    core_side = new SintyScreen((d, p) => relay(core_seen_by_viewer, viewer_side, p),
        (summary, body, allow, answer) => {
            core_asked++;
            if (core_holds) {
                held_answer = (owned) answer;
                return;
            }
            answer(core_answers ? "accept" : "decline");
        },
        () => "Living Room", (d) => loopback, bus, "/nonexistent/sinty-screen", Path.build_filename(dir, "core"));
    viewer_side = new SintyScreen((d, p) => relay(viewer_seen_by_core, core_side, p),
        (summary, body, allow, answer) => {
            viewer_asked++;
            answer("accept");
        },
        () => "Laptop", (d) => loopback, null, helper, Path.build_filename(dir, "viewer"));
    viewer_side.failed.connect((d, message) => failures += message);
    core_side.failed.connect((d, message) => failures += message);

    assert(core_side.is_core && !core_side.can_view);
    assert(viewer_side.can_view && !viewer_side.is_core);
    assert(core_side.can_show_on(viewer_seen_by_core));
    assert(viewer_side.can_show_from(core_seen_by_viewer));
    assert(!viewer_side.can_show_on(core_seen_by_viewer));

    Test.add_func("/screen/asks-once", test_a_screen_asks_once_then_is_remembered);
    Test.add_func("/screen/core-offers", test_the_core_offers_itself);
    Test.add_func("/screen/unasked", test_unasked_offers_and_forged_invites_do_nothing);
    Test.add_func("/screen/consent-once", test_a_screen_waiting_for_consent_is_asked_about_once);
    int result = Test.run();
    assert(failures.length == 0);
    return result;
}
