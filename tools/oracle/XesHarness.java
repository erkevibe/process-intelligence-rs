// Original observation adapter. No sorting/filtering or substitute XES model.
import org.apromore.splitminer.log.LogParser;
import org.apromore.splitminer.log.SimpleLog;
import org.deckfour.xes.in.XesXmlParser;
import org.deckfour.xes.factory.XFactoryNaiveImpl;
import org.deckfour.xes.classification.XEventNameClassifier;
import org.deckfour.xes.model.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class XesHarness {
  static String hex(String s) {
    if (s == null) return "-";
    StringBuilder b = new StringBuilder();
    for (byte v : s.getBytes(StandardCharsets.UTF_8)) b.append(String.format("%02x", v & 255));
    return b.toString();
  }
  static String attr(XAttributable v, String key) {
    XAttribute a = v.getAttributes().get(key);
    return a == null ? null : a.toString();
  }
  static String time(XEvent e) {
    XAttribute a = e.getAttributes().get("time:timestamp");
    return a instanceof XAttributeTimestamp ? Long.toString(((XAttributeTimestamp)a).getValueMillis()) : "-";
  }
  public static void main(String[] args) throws Exception {
    // No DTD/external entity probe: unchanged upstream SAX parser has its own
    // security defaults. This adapter never fetches arbitrary document URLs.
    try (InputStream in = new FileInputStream(args[0])) {
      List<XLog> logs = new XesXmlParser(new XFactoryNaiveImpl()).parse(in);
      if (logs.size() != 1) throw new IllegalStateException("Expected one XLog");
      XLog log = logs.get(0);
      System.out.println("log\t" + hex(attr(log, "concept:name")));
      for (int c=0; c<log.size(); c++) {
        XTrace trace=log.get(c);
        System.out.println("trace\t"+c+"\t"+hex(attr(trace,"concept:name")));
        for (int i=0; i<trace.size(); i++) {
          XEvent e=trace.get(i);
          XAttribute timestamp=e.getAttributes().get("time:timestamp");
          System.out.println("event\t"+c+"\t"+i+"\t"+hex(attr(e,"concept:name"))+"\t"+time(e)+"\t"+hex(attr(e,"lifecycle:transition"))+"\t"+(timestamp==null?"-":timestamp.getClass().getName())+"\t"+hex(attr(e,"time:timestamp")));
        }
      }
      SimpleLog simple=LogParser.getSimpleLog(log,new XEventNameClassifier());
      System.out.println("cases\t"+simple.size());
      System.out.println("activities\t"+simple.getDistinctEvents());
      System.out.println("raw_total_events\t"+simple.getTotalEvents());
      for (Map.Entry<String,Integer> entry:new TreeMap<>(simple.getTraces()).entrySet()) {
        List<String> labels=new ArrayList<>();
        for(String code:entry.getKey().split(":")) if(!code.isEmpty()) {
          int id=Integer.parseInt(code);
          if(id!=simple.getStartcode() && id!=simple.getEndcode()) labels.add(hex(simple.getEvents().get(id)));
        }
        System.out.println("variant\t"+entry.getValue()+"\t"+String.join(",",labels));
      }
    }
  }
}
