using Singularity.Nearby;

void test_roundtrip() {
    var p = new Packet(Packet.SHARE);
    p.set_string("filename", "photo \"1\".jpg");
    p.set_int("numberOfFiles", 2);
    p.set_bool("open", true);
    p.set_strv("list", { "a", "b" });
    p.payload_size = 1234;
    p.payload_port = 1739;
    string line = p.serialize();
    assert(line.has_suffix("\n"));
    assert(line.index_of_char('\n') == line.length - 1);
    var q = Packet.parse(line);
    assert(q.packet_type == Packet.SHARE);
    assert(q.get_string("filename") == "photo \"1\".jpg");
    assert(q.get_int("numberOfFiles") == 2);
    assert(q.get_bool("open"));
    var list = q.get_strv("list");
    assert(list.length == 2 && list[1] == "b");
    assert(q.has_payload);
    assert(q.payload_size == 1234);
    assert(q.payload_port == 1739);
    assert(q.id > 0);
}

void test_no_payload() {
    var q = Packet.parse("{\"id\":1,\"type\":\"kdeconnect.ping\",\"body\":{}}");
    assert(!q.has_payload);
    assert(q.payload_size == -1);
    assert(!q.serialize().contains("payloadSize"));
    var r = Packet.parse("{\"id\":1,\"type\":\"kdeconnect.share.request\",\"body\":{},\"payloadSize\":10}");
    assert(!r.has_payload);
}

void test_lenient_values() {
    var q = Packet.parse("{\"id\":\"1518846484880\",\"type\":\"kdeconnect.battery\",\"body\":{\"currentCharge\":\"57\",\"isCharging\":1,\"x\":2.0}}");
    assert(q.id == 1518846484880);
    assert(q.get_int("currentCharge") == 57);
    assert(q.get_bool("isCharging"));
    assert(q.get_int("x") == 2);
    assert(q.get_int("missing", 7) == 7);
    assert(q.get_string("missing", "d") == "d");
    assert(q.get_strv("missing").length == 0);
}

void test_invalid() {
    string[] bad = {
        "", "not json", "[]", "{\"body\":{}}", "{\"type\":5,\"body\":{}}", "{\"type\":\"x\",\"body\":[]}"
    };
    foreach (string b in bad) {
        bool thrown = false;
        try {
            Packet.parse(b);
        } catch (PacketError e) {
            thrown = true;
        }
        assert(thrown);
    }
}

void test_device_id_and_name() {
    assert(Packet.valid_device_id("0123456789abcdef0123456789abcdef"));
    assert(Packet.valid_device_id("_0123456789abcdef0123456789abcdef_"));
    assert(!Packet.valid_device_id("short"));
    assert(!Packet.valid_device_id("0123456789abcdef0123456789abcdef/"));
    assert(!Packet.valid_device_id(null));
    assert(Packet.filter_name("Mirko's <Phone>!") == "Mirkos Phone");
    assert(Packet.filter_name(string.nfill(40, 'a')).length == 32);
}

void test_verification_code() {
    var a = new Bytes({ 1, 2, 3 });
    var b = new Bytes({ 1, 2, 4 });
    string one = Packet.verification_code(a, b, 1700000000);
    string two = Packet.verification_code(b, a, 1700000000);
    assert(one == two);
    assert(one.length == 8);
    assert(one == one.up());
    var cs = new Checksum(ChecksumType.SHA256);
    cs.update({ 1, 2, 4 }, 3);
    cs.update({ 1, 2, 3 }, 3);
    cs.update("1700000000".data, 10);
    assert(one == cs.get_string().substring(0, 8).up());
    assert(Packet.verification_code(a, b, 1700000001) != one);
}

void test_certificates() {
    string cert, key;
    NearbyCerts.generate("0123456789abcdef0123456789abcdef", out cert, out key);
    assert(cert.has_prefix("-----BEGIN CERTIFICATE-----"));
    assert(key.contains("PRIVATE KEY"));
    assert(NearbyCerts.common_name(cert) == "0123456789abcdef0123456789abcdef");
    var der = NearbyCerts.public_key_der(cert);
    assert(der.get_size() > 60);
    var tls = new TlsCertificate.from_pem(cert + "\n" + key, -1);
    assert(tls != null);
}

void test_mdns_parse() {
    var m = new Mdns();
    m.instance = "self_self_self_self_self_self_self";
    string? found_id = null;
    int found_port = 0;
    string found_address = "";
    m.found.connect((addr, port, id, proto) => {
        found_id = id;
        found_port = port;
        found_address = addr.to_string();
        assert(proto == 8);
    });
    var b = new ByteArray();
    uint8[] header = { 0, 0, 0x84, 0, 0, 0, 0, 3, 0, 0, 0, 1 };
    b.append(header);
    string inst = "peer_peer_peer_peer_peer_peer_pe._kdeconnect._udp.local";
    DnsName.write(b, "_kdeconnect._udp.local");
    b.append({ 0, 12, 0, 1, 0, 0, 0x11, 0x94 });
    var ptr = new ByteArray();
    DnsName.write(ptr, inst);
    b.append({ 0, (uint8) ptr.len });
    b.append(ptr.data);
    DnsName.write(b, inst);
    b.append({ 0, 33, 0x80, 1, 0, 0, 0, 120 });
    var srv = new ByteArray();
    srv.append({ 0, 0, 0, 0, 0x06, 0xb4 });
    DnsName.write(srv, "peerhost.local");
    b.append({ 0, (uint8) srv.len });
    b.append(srv.data);
    DnsName.write(b, inst);
    b.append({ 0, 16, 0x80, 1, 0, 0, 0x11, 0x94 });
    var txt = new ByteArray();
    foreach (string item in new string[] { "id=peer_peer_peer_peer_peer_peer_pe", "protocol=8" }) {
        txt.append({ (uint8) item.length });
        txt.append(item.data);
    }
    b.append({ 0, (uint8) txt.len });
    b.append(txt.data);
    DnsName.write(b, "peerhost.local");
    b.append({ 0, 1, 0x80, 1, 0, 0, 0, 120, 0, 4, 10, 77, 0, 2 });
    m.parse(b.data, new InetAddress.from_string("192.168.1.9"));
    assert(found_id == "peer_peer_peer_peer_peer_peer_pe");
    assert(found_port == 1716);
    assert(found_address == "10.77.0.2");
}

void test_mdns_answers() {
    var m = new Mdns();
    m.instance = "self_self_self_self_self_self_self";
    assert(m.answers("_kdeconnect._udp.local", 12));
    assert(m.answers("self_self_self_self_self_self_self._kdeconnect._udp.local", 33));
    assert(m.answers("Self_self_self_self_self_self_self._kdeconnect._udp.local", 16));
    assert(m.answers("self_self_self_self_self_self_self.local", 1));
    assert(m.answers("self_self_self_self_self_self_self.local", 255));
    assert(!m.answers("self_self_self_self_self_self_self.local", 28));
    assert(!m.answers("peer_peer_peer_peer_peer_peer_pe._kdeconnect._udp.local", 33));
    assert(!m.answers("_kdeconnect._udp.local", 33));
}

void test_dns_compression() {
    uint8[] data = { 3, 'f', 'o', 'o', 5, 'l', 'o', 'c', 'a', 'l', 0, 3, 'b', 'a', 'r', 0xc0, 0 };
    int pos = 11;
    assert(DnsName.read(data, ref pos) == "bar.foo.local");
    assert(pos == 17);
    uint8[] loop = { 0xc0, 0 };
    pos = 0;
    assert(DnsName.read(loop, ref pos) == null);
}

void test_file_names() {
    assert(Files.safe_name("../../etc/passwd") == "passwd");
    assert(Files.safe_name(".bashrc") == "bashrc");
    assert(Files.safe_name("") == "file");
    assert(Files.safe_name("a\nb.txt") == "a b.txt");
    string dir = DirUtils.make_tmp("nearby-test-XXXXXX");
    assert(Files.unique_path(dir, "x.txt") == Path.build_filename(dir, "x.txt"));
    FileUtils.set_contents(Path.build_filename(dir, "x.txt"), "1");
    assert(Files.unique_path(dir, "x.txt") == Path.build_filename(dir, "x (1).txt"));
    FileUtils.remove(Path.build_filename(dir, "x.txt"));
    DirUtils.remove(dir);
}

void test_plugins() {
    var system = new SystemConfig();
    var d = new Device("0123456789abcdef0123456789abcdef");
    assert(!d.plugin_enabled("ping", system));
    d.record = new DeviceRecord(d.id);
    d.pair_state = PairState.PAIRED;
    assert(d.plugin_enabled("ping", system));
    assert(!d.plugin_enabled("runcommand", system));
    d.set_plugin("runcommand", true);
    assert(d.plugin_enabled("runcommand", system));
    system.allow_run_commands = false;
    assert(!d.plugin_enabled("runcommand", system));
    d.set_plugin("clipboard", false);
    assert(!d.plugin_enabled("clipboard", system));
    d.set_plugin("clipboard", true);
    assert(d.plugin_enabled("clipboard", system));
}

void test_received_history() {
    string dir = Path.build_filename(Environment.get_tmp_dir(), "nearby-history-" + Uuid.string_random());
    DirUtils.create_with_parents(dir, 0700);
    string file = Path.build_filename(dir, "received.json");
    string photo = Path.build_filename(dir, "photo.jpg");
    try {
        FileUtils.set_contents(photo, "12345");
    } catch (Error e) {
        assert_not_reached();
    }
    var h = new ReceivedHistory(file);
    int changes = 0;
    h.changed.connect(() => changes++);
    h.load();
    assert(h.entries.size == 0);
    h.add(photo, "dev1", "Pixel");
    h.add(Path.build_filename(dir, "gone.pdf"), "dev1", "Pixel");
    assert(h.entries.size == 2);
    assert(h.entries[0].path.has_suffix("gone.pdf"));
    assert(h.entries[1].size == 5);
    var d = h.entries[1].to_dict();
    assert(d["name"].get_string() == "photo.jpg");
    assert(d["exists"].get_boolean());
    assert(!h.entries[0].to_dict()["exists"].get_boolean());
    var again = new ReceivedHistory(file);
    again.load();
    assert(again.entries.size == 2);
    assert(again.entries[1].device_name == "Pixel");
    h.forget(photo);
    assert(h.entries.size == 1);
    h.forget("/nope");
    for (int i = 0; i < ReceivedHistory.LIMIT + 5; i++) h.add(photo, "dev1", "Pixel");
    assert(h.entries.size == ReceivedHistory.LIMIT);
    h.clear();
    assert(h.entries.size == 0);
    assert(changes == ReceivedHistory.LIMIT + 5 + 4);
    FileUtils.remove(photo);
    FileUtils.remove(file);
    DirUtils.remove(dir);
}

void test_transfer_info() {
    var t = new TransferInfo("t1");
    t.device_id = "dev";
    t.batch = "b";
    t.name = "a.txt";
    t.total = 10;
    var d = t.to_dict();
    assert(d["state"].get_string() == "running");
    assert(d["batch"].get_string() == "b");
    assert(d["total"].get_int64() == 10);
    var n = new PhoneNotification("k1");
    n.reply_id = "r";
    n.actions = { "Snooze" };
    var nd = n.to_dict();
    assert(nd["can-reply"].get_boolean());
    assert(nd["actions"].get_strv()[0] == "Snooze");
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/nearby/packet/roundtrip", test_roundtrip);
    Test.add_func("/nearby/packet/no-payload", test_no_payload);
    Test.add_func("/nearby/packet/lenient", test_lenient_values);
    Test.add_func("/nearby/packet/invalid", test_invalid);
    Test.add_func("/nearby/packet/ids", test_device_id_and_name);
    Test.add_func("/nearby/pairing/code", test_verification_code);
    Test.add_func("/nearby/pairing/certificates", test_certificates);
    Test.add_func("/nearby/mdns/parse", test_mdns_parse);
    Test.add_func("/nearby/mdns/answers", test_mdns_answers);
    Test.add_func("/nearby/mdns/compression", test_dns_compression);
    Test.add_func("/nearby/files/names", test_file_names);
    Test.add_func("/nearby/plugins/toggles", test_plugins);
    Test.add_func("/nearby/history/received", test_received_history);
    Test.add_func("/nearby/transfers/info", test_transfer_info);
    return Test.run();
}
