int failures = 0;

void check(bool ok, string what) {
    print("%s %s\n", ok ? "ok" : "not ok", what);
    if (!ok) failures++;
}

bool opens(string key, string cert, string context, Bytes sealed) {
    try {
        int64 ts;
        NearbyEnvelope.open(key, cert, context, sealed, out ts);
        return true;
    } catch (Error e) {
        return false;
    }
}

bool contains(Bytes hay, string needle) {
    unowned uint8[] h = hay.get_data();
    unowned uint8[] n = needle.data;
    for (int i = 0; i + n.length <= h.length; i++) {
        if (Memory.cmp(&h[i], &n[0], n.length) == 0) return true;
    }
    return false;
}

int main() {
    string laptop_cert, laptop_key, studio_cert, studio_key, other_cert, other_key;
    try {
        NearbyCerts.generate("laptop", out laptop_cert, out laptop_key);
        NearbyCerts.generate("studio", out studio_cert, out studio_key);
        NearbyCerts.generate("stranger", out other_cert, out other_key);
    } catch (Error e) {
        print("not ok keys: %s\n", e.message);
        return 1;
    }
    string secret = "Top secret draft: the quarterly numbers nobody may read";
    var plain = new Bytes(secret.data);
    string context = "sinty.app.move/laptop/studio/transfer-1";
    Bytes sealed;
    try {
        sealed = NearbyEnvelope.seal(laptop_key, studio_cert, context, 1763900000, plain);
    } catch (Error e) {
        print("not ok seal: %s\n", e.message);
        return 1;
    }
    check(!contains(sealed, "quarterly"), "the sealed package does not contain the plain text");
    try {
        int64 ts;
        var back = NearbyEnvelope.open(studio_key, laptop_cert, context, sealed, out ts);
        check(back.compare(plain) == 0 && ts == 1763900000, "the paired receiver opens it byte for byte");
    } catch (Error e) {
        check(false, "the paired receiver opens it: " + e.message);
    }
    check(!opens(other_key, laptop_cert, context, sealed), "a third device cannot open it");
    check(!opens(studio_key, other_cert, context, sealed), "it is refused when the expected sender is someone else");
    check(!opens(studio_key, laptop_cert, "sinty.app.move/laptop/studio/transfer-2", sealed), "it cannot be replayed as another transfer");
    check(!opens(studio_key, laptop_cert, "sinty.app.move/laptop/stranger/transfer-1", sealed), "it cannot be redirected to another device");
    try {
        var forged = NearbyEnvelope.seal(other_key, studio_cert, context, 1763900000, plain);
        check(!opens(studio_key, laptop_cert, context, forged), "a package sealed by an unpaired device is refused");
    } catch (Error e) {
        check(false, "forged seal: " + e.message);
    }
    uint8[] raw = sealed.get_data();
    int flips = 0;
    for (int i = 0; i < raw.length; i += 7) {
        uint8[] copy = raw;
        copy[i] ^= 0x01;
        if (opens(studio_key, laptop_cert, context, new Bytes(copy))) flips++;
    }
    check(flips == 0, "changing any single byte makes it unopenable (%d accepted)".printf(flips));
    print(failures == 0 ? "all ok\n" : "%d failures\n".printf(failures));
    return failures == 0 ? 0 : 1;
}
