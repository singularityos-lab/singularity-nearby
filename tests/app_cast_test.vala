using Singularity.Nearby;

const string APP = "dev.sinty.CastTest";
const string SERVE_KEY = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
const string SHOW_KEY = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=";

class Side {
    public UserConfig config;
    public AppCast cast;
    public bool deaf = false;
    public Gee.HashMap<string, Device> peers = new Gee.HashMap<string, Device>();
    public Gee.ArrayList<Packet> received = new Gee.ArrayList<Packet>();
}

Gee.HashMap<string, Side> sides;
Side laptop;
Side studio;
Side stranger;
string dir;
int failures = 0;

void check(bool ok, string what) {
    print("%s %s\n", ok ? "ok" : "not ok", what);
    if (!ok) failures++;
}

void deliver(Side from, Device to_device, Packet p) {
    var to = sides[to_device.id];
    var seen_as = to.peers[from.config.device_id];
    if (seen_as == null || to.deaf) return;
    try {
        var copy = Packet.parse(p.serialize());
        Idle.add(() => {
            to.received.add(copy);
            to.cast.handle(seen_as, copy);
            return Source.REMOVE;
        });
    } catch (Error e) {
        error(e.message);
    }
}

void write_file(string path, string text) {
    try {
        DirUtils.create_with_parents(Path.get_dirname(path), 0700);
        FileUtils.set_contents(path, text);
    } catch (Error e) {
        error(e.message);
    }
}

string read_file(string name) {
    string text;
    try {
        FileUtils.get_contents(Path.build_filename(dir, name), out text);
    } catch (Error e) {
        return "";
    }
    return text;
}

int count_lines(string name) {
    string text = read_file(name);
    return text == "" ? 0 : text.strip().split("\n").length;
}

Side make_side(string root, string name, string binary) {
    var s = new Side();
    s.config = new UserConfig(Path.build_filename(root, name, "nearby"));
    try {
        s.config.load();
    } catch (Error e) {
        error(e.message);
    }
    s.cast = new AppCast((d, p) => deliver(s, d, p), (d) => new InetAddress.loopback(SocketFamily.IPV4), s.config, binary);
    sides[s.config.device_id] = s;
    return s;
}

Device see(Side a, Side b, bool paired) {
    var d = new Device(b.config.device_id);
    d.name = b.config.device_name;
    d.record = new DeviceRecord(b.config.device_id);
    d.record.certificate = b.config.certificate_pem;
    d.pair_state = paired ? PairState.PAIRED : PairState.NONE;
    d.incoming = { AppCast.OFFER, AppCast.RESULT };
    a.peers[b.config.device_id] = d;
    return d;
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

class Run {
    public bool done = false;
    public string? failure = null;
}

Run start_cast(Side from, Side to, string transfer = Uuid.string_random()) {
    var run = new Run();
    from.cast.cast.begin(from.peers[to.config.device_id], transfer, APP, 0, "Cast Test", (o, r) => {
        try {
            from.cast.cast.end(r);
        } catch (Error e) {
            run.failure = e.message;
        }
        run.done = true;
    });
    return run;
}

string? run_cast(Side from, Side to) {
    var run = start_cast(from, to);
    wait_for(() => run.done, 20);
    return run.done ? run.failure : "timed out";
}

Packet sealed_offer(Side from, Side to, string transfer, string context_app, int64 stamp, string body) {
    try {
        var sealed = NearbyEnvelope.seal(from.config.private_key_pem, to.config.certificate_pem,
            AppCast.context(AppCast.OFFER, from.config.device_id, to.config.device_id, transfer, context_app), stamp, new Bytes(body.data));
        return new Packet(AppCast.OFFER).set_string("transfer", transfer).set_string("app", APP).set_string("sealed", Base64.encode(sealed.get_data()));
    } catch (Error e) {
        error(e.message);
    }
}

const string BODY = "{\"port\":4242,\"key\":\"" + SERVE_KEY + "\",\"width\":320,\"height\":200,\"title\":\"Cast Test\"}";

Packet? last_result(Side s) {
    for (int i = s.received.size - 1; i >= 0; i--) {
        if (s.received[i].packet_type == AppCast.RESULT) return s.received[i];
    }
    return null;
}

bool refused_without_showing(Side from, Packet offer, string what) {
    int shows = count_lines("show.args");
    from.received.clear();
    studio.cast.handle(studio.peers[from.config.device_id], offer);
    wait_for(() => last_result(from) != null, 5);
    spin(200);
    var result = last_result(from);
    bool refused = result != null && !result.get_bool("ok", true);
    print("# %s: %s\n", what, result != null ? result.get_string("message", "") : "no answer");
    return refused && count_lines("show.args") == shows;
}

bool alive(string pid_file) {
    int pid = int.parse(read_file(pid_file).strip());
    return pid > 0 && Posix.kill(pid, 0) == 0;
}

int main(string[] args) {
    Environment.set_variable("WAYLAND_DISPLAY", "cast-test", true);
    string root;
    try {
        root = DirUtils.make_tmp("app-cast-XXXXXX");
    } catch (Error e) {
        error(e.message);
    }
    dir = root;
    string binary = Path.build_filename(root, "sinty-screen");
    write_file(binary, """#!/bin/sh
D=%s
case "$1" in
-cast-serve)
  echo $$ > $D/serve.pid
  echo '{"event":"ready","port":4242,"key":"%s","width":320,"height":200}'
  while read line; do
    echo "$line" >> $D/serve.stdin
    case "$line" in *trust*) echo '{"event":"showing"}';; esac
  done
  ;;
-cast-show)
  echo "$@" >> $D/show.args
  if [ -e $D/fail ]; then echo '{"event":"ended","error":"no window here"}'; exit 1; fi
  echo '{"event":"identity","key":"%s"}'
  exec sleep 120
  ;;
esac
""".printf(root, SERVE_KEY, SHOW_KEY));
    FileUtils.chmod(binary, 0755);
    sides = new Gee.HashMap<string, Side>();
    laptop = make_side(root, "laptop", binary);
    studio = make_side(root, "studio", binary);
    stranger = make_side(root, "stranger", binary);
    see(laptop, studio, true);
    see(studio, laptop, true);
    see(stranger, studio, true);
    see(studio, stranger, false);
    see(laptop, stranger, true);

    check(laptop.cast.can_cast_to(laptop.peers[studio.config.device_id]), "a paired device that advertises the capability can show apps");
    check(!studio.cast.can_cast_to(studio.peers[stranger.config.device_id]), "an unpaired device cannot");

    string? failure = run_cast(laptop, studio);
    check(failure == null, "a paired laptop shows its app on the studio (%s)".printf(failure ?? "ok"));
    string show = read_file("show.args");
    check(("-cast-key " + SERVE_KEY) in show && "-core 127.0.0.1:4242" in show && "-window-size 320x200" in show && ("-app " + APP) in show,
        "the studio connects to the key and port the laptop sealed for it");
    check(SHOW_KEY in read_file("serve.stdin"), "the laptop trusts only the screen key the studio sealed back");

    Packet? offer = null;
    foreach (var p in studio.received) {
        if (p.packet_type == AppCast.OFFER) offer = p;
    }
    Packet? answer = null;
    foreach (var p in laptop.received) {
        if (p.packet_type == AppCast.RESULT && p.get_bool("ok", false)) answer = p;
    }
    check(answer != null && answer.get_bool("ok", false) && answer.get_string("sealed", "") != "", "the studio answers with a sealed screen key");
    if (answer != null) {
        studio.received.clear();
        laptop.cast.handle(laptop.peers[studio.config.device_id], new Packet(AppCast.OFFER).set_string("transfer", answer.get_string("transfer", ""))
            .set_string("app", APP).set_string("sealed", answer.get_string("sealed", "")));
        wait_for(() => last_result(studio) != null, 5);
        var reflected = last_result(studio);
        print("# answer sent back as an offer: %s\n", reflected != null ? reflected.get_string("message", "") : "no answer");
        check(reflected != null && !reflected.get_bool("ok", true) && "signed" in reflected.get_string("message", ""),
            "a sealed answer cannot be opened as an offer");
    }
    check(offer != null && !(SERVE_KEY in offer.serialize()), "the offer on the wire carries no readable key");
    check(offer != null && refused_without_showing(laptop, offer, "replay"), "the same offer sent again is refused");

    string fresh = Uuid.string_random();
    int64 now = get_real_time() / TimeSpan.SECOND;
    check(refused_without_showing(laptop, sealed_offer(laptop, studio, fresh, APP, now - AppCast.FRESHNESS - 60, BODY), "old offer"),
        "an offer sealed too long ago is refused");
    check(refused_without_showing(laptop, sealed_offer(laptop, studio, Uuid.string_random(), "dev.sinty.Other", now, BODY), "other app"),
        "an offer sealed for another app is refused");
    check(refused_without_showing(laptop, sealed_offer(laptop, studio, Uuid.string_random(), APP, now,
        "{\"port\":4242,\"key\":\"AQEB\",\"width\":320,\"height\":200}"), "short key"), "an offer with a key of the wrong size is refused");
    var tampered = sealed_offer(laptop, studio, Uuid.string_random(), APP, now, BODY);
    string blob = tampered.get_string("sealed", "");
    int at = blob.length / 2;
    tampered.set_string("sealed", blob.substring(0, at) + (blob[at] == 'A' ? "B" : "A") + blob.substring(at + 1));
    check(refused_without_showing(laptop, tampered, "changed"), "an offer changed on the way is refused");
    check(refused_without_showing(laptop, sealed_offer(stranger, studio, Uuid.string_random(), APP, now, BODY), "sealed by another device"),
        "an offer sealed by another device is refused");

    int shows = count_lines("show.args");
    stranger.received.clear();
    var lost = start_cast(stranger, studio);
    spin(1000);
    check(count_lines("show.args") == shows && last_result(stranger) == null, "the studio ignores an unpaired device without showing anything");
    stranger.cast.forget(stranger.peers[studio.config.device_id]);
    wait_for(() => lost.done, 5);
    check(lost.done && lost.failure != null && !alive("serve.pid"), "the unpaired device's own serving side is stopped");

    studio.deaf = true;
    string waiting = Uuid.string_random();
    var held = start_cast(laptop, studio, waiting);
    spin(500);
    var forged = new Packet(AppCast.RESULT).set_string("transfer", waiting).set_bool("ok", false).set_string("message", "forged");
    laptop.cast.handle(laptop.peers[stranger.config.device_id], forged);
    spin(300);
    check(!held.done, "an answer from a device the app was not sent to is ignored");
    try {
        var stale = NearbyEnvelope.seal(studio.config.private_key_pem, laptop.config.certificate_pem,
            AppCast.context(AppCast.RESULT, studio.config.device_id, laptop.config.device_id, waiting, APP),
            now - AppCast.FRESHNESS - 60, new Bytes(("{\"key\":\"" + SHOW_KEY + "\"}").data));
        int before = count_lines("serve.stdin");
        laptop.cast.handle(laptop.peers[studio.config.device_id], new Packet(AppCast.RESULT).set_string("transfer", waiting)
            .set_bool("ok", true).set_string("sealed", Base64.encode(stale.get_data())));
        wait_for(() => held.done, 5);
        spin(300);
        print("# old answer: %s\n", held.failure ?? "accepted");
        check(held.done && held.failure != null && count_lines("serve.stdin") == before && !alive("serve.pid"),
            "an answer sealed too long ago is refused and the laptop stops serving");
    } catch (Error e) {
        error(e.message);
    }
    studio.deaf = false;

    write_file(Path.build_filename(root, "fail"), "");
    failure = run_cast(laptop, studio);
    spin(300);
    print("# studio fails: %s\n", failure ?? "accepted");
    check(failure != null && !alive("serve.pid"), "when the studio cannot show the window the laptop stops serving it");

    laptop.cast.stop_all();
    studio.cast.stop_all();
    spin(300);
    print(failures == 0 ? "all ok\n" : "%d failed\n".printf(failures));
    return failures == 0 ? 0 : 1;
}
