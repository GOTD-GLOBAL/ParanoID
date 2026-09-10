package org.paranoid.text;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Volatile, strictly validated RFC0018 credentials. Never serialize or log this object. */
public final class VoiceRelayConfig {
    private static final long MIN_REMAINING_MILLIS = 1000000L;
    private static final long MAX_REMAINING_MILLIS = 1205000L;
    private static final Pattern ORIGIN = Pattern.compile(
            "https://([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)(?::([1-9][0-9]{0,4}))?");
    private final List<String> urls;
    private final String username;
    private final String password;
    private final long expiresMillis;
    private final long receiptNanos;
    private final long admissionBudgetNanos;

    private VoiceRelayConfig(List<String> urls, String username, String password,
            long expiresMillis, long receiptNanos, long remainingMillis) {
        this.urls = Collections.unmodifiableList(new ArrayList<>(urls));
        this.username = username;
        this.password = password;
        this.expiresMillis = expiresMillis;
        this.receiptNanos = receiptNanos;
        // Receipt bounds make this multiplication safe. Preserve sub-millisecond elapsed time.
        this.admissionBudgetNanos = (remainingMillis - MIN_REMAINING_MILLIS) * 1000000L;
    }

    public List<String> urls() { return urls; }
    public String username() { return username; }
    public String password() { return password; }

    /** Recheck immediately before creating media, including after asynchronous old-engine disposal. */
    public boolean usable(long wallMillis, long monoNanos) {
        if (wallMillis < 0) return false;
        try {
            long elapsed = Math.subtractExact(monoNanos, receiptNanos);
            long wallRemaining = Math.subtractExact(expiresMillis, wallMillis);
            return elapsed >= 0 && elapsed <= admissionBudgetNanos
                    && wallRemaining >= MIN_REMAINING_MILLIS;
        } catch (ArithmeticException invalidClock) {
            return false;
        }
    }

    @Override public String toString() { return "VoiceRelayConfig[redacted]"; }

    public static VoiceRelayConfig parse(byte[] bytes, String realm,
            long wallMillis, long monoNanos) throws IOException {
        if (bytes == null || bytes.length == 0 || bytes.length > 2048)
            throw new IOException("relay metadata size");
        String host = realmHost(realm);
        String text = StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString();
        Map<String, Object> fields = new Parser(text).object();
        if (fields.size() != 6 || number(fields, "v") != 1 || number(fields, "ttl") != 1200)
            throw new IOException("relay metadata schema");
        Object rawUrls = fields.get("urls");
        if (!(rawUrls instanceof List)) throw new IOException("relay URL shape");
        List<?> values = (List<?>) rawUrls;
        String udp = "turn:" + host + ":34781?transport=udp";
        String tcp = "turn:" + host + ":34781?transport=tcp";
        if (values.size() != 2 || !udp.equals(values.get(0)) || !tcp.equals(values.get(1)))
            throw new IOException("relay URL binding");
        long expires = number(fields, "expires");
        String username = string(fields, "username");
        String password = string(fields, "credential");
        if (!username.matches(Long.toString(expires) + ":[0-9a-f]{32}"))
            throw new IOException("relay username binding");
        if (!password.matches("[A-Za-z0-9+/]{27}="))
            throw new IOException("relay credential encoding");
        try {
            byte[] decoded = Base64.getDecoder().decode(password);
            if (decoded.length != 20 || !Base64.getEncoder().encodeToString(decoded).equals(password))
                throw new IOException("relay credential encoding");
        } catch (IllegalArgumentException invalidEncoding) {
            throw new IOException("relay credential encoding");
        }
        try {
            long expiresMillis = Math.multiplyExact(expires, 1000L);
            long remainingMillis = Math.subtractExact(expiresMillis, wallMillis);
            if (wallMillis < 0 || remainingMillis < MIN_REMAINING_MILLIS
                    || remainingMillis > MAX_REMAINING_MILLIS)
                throw new IOException("relay credential lifetime");
            List<String> urls = new ArrayList<>(2);
            urls.add(udp);
            urls.add(tcp);
            return new VoiceRelayConfig(urls, username, password,
                    expiresMillis, monoNanos, remainingMillis);
        } catch (ArithmeticException invalidTime) {
            throw new IOException("relay credential lifetime");
        }
    }

    /** A literal canonical IPv4 origin; this check never resolves a hostname. */
    private static String realmHost(String realm) throws IOException {
        if (realm == null || realm.length() > 64) throw new IOException("relay realm");
        Matcher match = ORIGIN.matcher(realm);
        if (!match.matches()) throw new IOException("relay realm");
        String host = match.group(1);
        for (String octet : host.split("\\.", -1)) {
            if (octet.length() > 3 || (octet.length() > 1 && octet.charAt(0) == '0')
                    || Integer.parseInt(octet) > 255) throw new IOException("relay realm");
        }
        if (match.group(2) != null && Integer.parseInt(match.group(2)) > 65535)
            throw new IOException("relay realm");
        return host;
    }

    private static long number(Map<String, Object> fields, String key) throws IOException {
        Object value = fields.get(key);
        if (!(value instanceof Long) || ((Long) value) <= 0)
            throw new IOException("relay positive integer required");
        return (Long) value;
    }

    private static String string(Map<String, Object> fields, String key) throws IOException {
        Object value = fields.get(key);
        if (!(value instanceof String)) throw new IOException("relay string required");
        return (String) value;
    }

    /** Bounded, nonrecursive grammar shared by the host JVM and Android. */
    private static final class Parser {
        private final String source;
        private int position;
        Parser(String source) { this.source = source; }

        private void space() {
            while (position < source.length() && " \r\n\t".indexOf(source.charAt(position)) >= 0)
                position++;
        }
        private char take() throws IOException {
            if (position >= source.length()) throw new IOException("relay truncated JSON");
            return source.charAt(position++);
        }
        private void expect(char expected) throws IOException {
            space();
            if (take() != expected) throw new IOException("relay JSON syntax");
        }
        private String text() throws IOException {
            expect('"');
            StringBuilder result = new StringBuilder();
            while (true) {
                char next = take();
                if (next == '"') break;
                if (next < 32) throw new IOException("relay JSON control");
                if (next == '\\') {
                    next = take();
                    switch (next) {
                        case '"': case '\\': case '/': break;
                        case 'b': next = '\b'; break;
                        case 'f': next = '\f'; break;
                        case 'n': next = '\n'; break;
                        case 'r': next = '\r'; break;
                        case 't': next = '\t'; break;
                        case 'u':
                            int value = 0;
                            for (int i = 0; i < 4; i++) {
                                char digit = take();
                                int decoded = "0123456789abcdefABCDEF".indexOf(digit);
                                if (decoded < 0) throw new IOException("relay JSON escape");
                                value = value * 16 + (decoded > 15 ? decoded - 6 : decoded);
                            }
                            next = (char) value;
                            break;
                        default: throw new IOException("relay JSON escape");
                    }
                }
                result.append(next);
            }
            String value = result.toString();
            for (int i = 0; i < value.length(); i++) {
                char next = value.charAt(i);
                if (Character.isHighSurrogate(next)) {
                    if (++i >= value.length() || !Character.isLowSurrogate(value.charAt(i)))
                        throw new IOException("relay JSON surrogate");
                } else if (Character.isLowSurrogate(next)) {
                    throw new IOException("relay JSON surrogate");
                }
            }
            return value;
        }
        private long integer() throws IOException {
            space();
            int start = position;
            while (position < source.length() && source.charAt(position) >= '0'
                    && source.charAt(position) <= '9') position++;
            String digits = source.substring(start, position);
            if (digits.isEmpty() || (digits.length() > 1 && digits.charAt(0) == '0'))
                throw new IOException("relay JSON integer");
            try { return Long.parseLong(digits); }
            catch (NumberFormatException overflow) { throw new IOException("relay JSON integer overflow"); }
        }
        private List<String> urls() throws IOException {
            expect('[');
            List<String> values = new ArrayList<>(2);
            values.add(text());
            expect(',');
            values.add(text());
            expect(']');
            return values;
        }
        Map<String, Object> object() throws IOException {
            Map<String, Object> fields = new HashMap<>();
            expect('{');
            while (true) {
                String key = text();
                if (fields.containsKey(key)) throw new IOException("relay duplicate field");
                expect(':');
                Object value;
                switch (key) {
                    case "v": case "expires": case "ttl": value = integer(); break;
                    case "username": case "credential": value = text(); break;
                    case "urls": value = urls(); break;
                    default: throw new IOException("relay unknown field");
                }
                fields.put(key, value);
                space();
                char next = take();
                if (next == '}') break;
                if (next != ',') throw new IOException("relay JSON separator");
            }
            space();
            if (position != source.length()) throw new IOException("relay JSON trailing input");
            return fields;
        }
    }
}
