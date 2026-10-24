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

final class SplitMinerBenchmarkXesObserver {
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

}
