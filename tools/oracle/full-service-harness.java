// Own observation adapter. It does not replace, extract, or edit upstream code.
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayInputStream;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.deckfour.xes.classification.XEventClassifier;
import org.deckfour.xes.extension.XExtension;
import org.deckfour.xes.factory.XFactory;
import org.deckfour.xes.factory.XFactoryRegistry;
import org.deckfour.xes.in.XParser;
import org.deckfour.xes.in.XParserRegistry;
import org.deckfour.xes.model.*;

final class FullServiceHarness {
    static Map<String, Object> object(Object... fields) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (int i = 0; i < fields.length; i += 2) out.put((String) fields[i], fields[i + 1]);
        return out;
    }

    static String sha(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder out = new StringBuilder();
        for (byte b : digest) out.append(String.format("%02x", b & 255));
        return out.toString();
    }

    static List<Map<String, Object>> attributes(Iterable<XAttribute> input, int depth) {
        if (depth > 32) throw new IllegalStateException("observation depth bound");
        List<XAttribute> sorted = new ArrayList<>();
        for (XAttribute a : input) sorted.add(a);
        sorted.sort(Comparator.comparing(XAttribute::getKey));
        List<Map<String, Object>> result = new ArrayList<>();
        for (XAttribute a : sorted) result.add(attribute(a, depth));
        return result;
    }

    static Map<String, Object> attribute(XAttribute a, int depth) {
        if (depth > 32) throw new IllegalStateException("observation depth bound");
        String type;
        Object value;
        // OpenXES collections inherit Literal for backwards compatibility.
        // Test the more specific collection interfaces before the scalar one.
        if (a instanceof XAttributeList) {
            type = "list";
            List<Map<String, Object>> values = new ArrayList<>();
            for (XAttribute child : ((XAttributeList) a).getCollection()) values.add(attribute(child, depth + 1));
            value = values;
        }
        else if (a instanceof XAttributeContainer) {
            type = "container";
            value = attributes(((XAttributeContainer) a).getCollection(), depth + 1);
        }
        else if (a instanceof XAttributeLiteral) { type = "string"; value = ((XAttributeLiteral) a).getValue(); }
        else if (a instanceof XAttributeTimestamp) { type = "date"; value = ((XAttributeTimestamp) a).getValueMillis(); }
        else if (a instanceof XAttributeDiscrete) { type = "int"; value = ((XAttributeDiscrete) a).getValue(); }
        else if (a instanceof XAttributeContinuous) { type = "float"; value = ((XAttributeContinuous) a).getValue(); }
        else if (a instanceof XAttributeBoolean) { type = "boolean"; value = ((XAttributeBoolean) a).getValue(); }
        else if (a instanceof XAttributeID) { type = "id"; value = ((XAttributeID) a).getValue().toString(); }
        else throw new IllegalStateException("unobserved attribute implementation: " + a.getClass().getName());
        Map<String, Object> out = object("key", a.getKey(), "type", type, "value", value);
        if (a instanceof XAttributeTimestamp) out.put("text", a.toString());
        if (!(a instanceof XAttributeContainer) && !a.getAttributes().isEmpty()) {
            out.put("children", attributes(a.getAttributes().values(), depth + 1));
        }
        return out;
    }

    static Map<String, Object> log(XLog log) {
        List<Map<String, Object>> classifiers = new ArrayList<>();
        for (XEventClassifier c : log.getClassifiers()) classifiers.add(object("name", c.name(), "keys", c.getDefiningAttributeKeys()));
        List<Map<String, Object>> extensions = new ArrayList<>();
        List<XExtension> sorted = new ArrayList<>(log.getExtensions());
        sorted.sort(Comparator.comparing(e -> e.getUri().toString()));
        for (XExtension e : sorted) extensions.add(object("name", e.getName(), "prefix", e.getPrefix(), "uri", e.getUri().toString()));
        List<Map<String, Object>> traces = new ArrayList<>();
        long count = 0;
        for (XTrace trace : log) {
            List<Map<String, Object>> events = new ArrayList<>();
            for (XEvent event : trace) {
                events.add(object("attributes", attributes(event.getAttributes().values(), 0)));
                count++;
            }
            traces.add(object("attributes", attributes(trace.getAttributes().values(), 0), "events", events));
        }
        return object("attributes", attributes(log.getAttributes().values(), 0),
                "classifiers", classifiers, "extensions", extensions,
                "global_trace_attributes", attributes(log.getGlobalTraceAttributes(), 0),
                "global_event_attributes", attributes(log.getGlobalEventAttributes(), 0),
                "traces", traces, "trace_count", traces.size(), "event_count", count);
    }

    static final class ObservedStream extends FilterInputStream {
        long bytesRead, readCalls, markCalls, resetCalls;
        ObservedStream(byte[] data) { super(new ByteArrayInputStream(data)); }
        @Override public int read() throws IOException {
            int n = in.read(); readCalls++; if (n >= 0) bytesRead++; return n;
        }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            int n = in.read(b, off, len); readCalls++; if (n > 0) bytesRead += n; return n;
        }
        @Override public synchronized void mark(int limit) { markCalls++; in.mark(limit); }
        @Override public synchronized void reset() throws IOException { resetCalls++; in.reset(); }
    }

    static void selfTest(Path output) throws Exception {
        XFactory factory = XFactoryRegistry.instance().currentDefault();
        XAttributeList list = factory.createAttributeList("costs", null);
        list.addToCollection(factory.createAttributeDiscrete("item", 3, null));
        list.addToCollection(factory.createAttributeDiscrete("item", 7, null));
        Map<String, Object> listView = attribute(list, 0);
        if (!(list instanceof XAttributeLiteral) || !"list".equals(listView.get("type"))) throw new IllegalStateException("collection literal inheritance dispatch");
        List<?> values = (List<?>) listView.get("value");
        if (values.size() != 2 || ((Number) ((Map<?, ?>) values.get(0)).get("value")).longValue() != 3 || ((Number) ((Map<?, ?>) values.get(1)).get("value")).longValue() != 7) throw new IllegalStateException("list duplicate-key ordering");
        XAttributeContainer container = factory.createAttributeContainer("address", null);
        container.getAttributes().put("city", factory.createAttributeLiteral("city", "Almaty", null));
        Map<String, Object> containerView = attribute(container, 0);
        if (!(container instanceof XAttributeLiteral) || !"container".equals(containerView.get("type")) || ((List<?>) containerView.get("value")).size() != 1) throw new IllegalStateException("container inherited-literal dispatch");
        Map<String, Object> scalar = attribute(factory.createAttributeLiteral("empty", "", null), 0);
        if (!"string".equals(scalar.get("type")) || !"".equals(scalar.get("value"))) throw new IllegalStateException("empty literal remains scalar");
        Map<String, Object> proof = object("status", "PASS", "scope", "Actual pinned OpenXES observer type-hierarchy regression only; no service invocation", "list_is_literal", true, "container_is_literal", true, "list", listView, "container", containerView, "empty_literal", scalar);
        Files.write(output, new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsBytes(proof), StandardOpenOption.CREATE_NEW);
        System.out.println("ACTUAL_OBSERVER_INHERITANCE_REGRESSION_PASS");
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 2 && "--self-test".equals(args[0])) { selfTest(Path.of(args[1])); return; }
        if (args.length != 3) throw new IllegalArgumentException("input extension NEW-output-json required");
        Path input = Path.of(args[0]);
        if (Files.size(input) > 1024 * 1024) throw new IllegalArgumentException("trusted fixture input cap");
        byte[] bytes = Files.readAllBytes(input);
        Class<?> service = Class.forName("org.apromore.service.impl.EventLogServiceImpl");
        XFactory factory = XFactoryRegistry.instance().currentDefault();
        Method importer = service.getDeclaredMethod("importFromStream", XFactory.class, InputStream.class, String.class);
        importer.setAccessible(true);
        List<String> parsers = new ArrayList<>();
        for (XParser p : XParserRegistry.instance().getAvailable()) parsers.add(p.getClass().getName());
        byte[] classBytes;
        try (InputStream code = service.getResourceAsStream("EventLogServiceImpl.class")) {
            if (code == null) throw new IllegalStateException("service class byte identity missing");
            classBytes = code.readAllBytes();
        }
        Map<String, Object> out = object("schema_version", 1, "input_sha256", sha(bytes),
                "selected_path", "unchanged_full_class.private.importFromStream",
                "public_importLog_executed", false, "assertions_enabled", service.desiredAssertionStatus(),
                "factory", factory.getClass().getName(), "parser_registry", parsers,
                "service_class_sha256", sha(classBytes),
                "service_class_origin", service.getProtectionDomain().getCodeSource().getLocation().toString(),
                "extension", args[1]);
        ObservedStream stream = new ObservedStream(bytes);
        try {
            XLog result = (XLog) importer.invoke(null, factory, stream, args[1]);
            out.put("status", "success"); out.put("log", log(result));
        } catch (InvocationTargetException wrapped) {
            Throwable cause = wrapped.getCause();
            out.put("status", "refused");
            out.put("exception", object("class", cause.getClass().getName(), "message", cause.getMessage()));
        } finally {
            out.put("stream", object("bytes_read", stream.bytesRead, "read_calls", stream.readCalls,
                    "mark_calls", stream.markCalls, "reset_calls", stream.resetCalls,
                    "adapter_rewind", false, "implementation", "ByteArrayInputStream wrapped for observation"));
        }
        byte[] json = new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsBytes(out);
        if (json.length > 1024 * 1024) throw new IllegalStateException("observation output cap");
        Files.write(Path.of(args[2]), json, StandardOpenOption.CREATE_NEW);
        System.out.println("FULL_SERVICE_OBSERVATION " + out.get("status"));
    }
}
