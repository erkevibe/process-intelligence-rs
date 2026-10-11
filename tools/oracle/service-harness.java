// Observation adapter only. Filtering executes exact extracted upstream bodies.
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.deckfour.xes.factory.XFactoryNaiveImpl;
import org.deckfour.xes.in.XesXmlParser;
import org.deckfour.xes.model.*;

class ServiceHarness {
  static final IdentityHashMap<XTrace,Integer> traces=new IdentityHashMap<>();
  static final IdentityHashMap<XEvent,Integer> events=new IdentityHashMap<>();
  static String hex(String s) {
    if(s==null)return "-";
    StringBuilder b=new StringBuilder();
    for(byte v:s.getBytes(StandardCharsets.UTF_8))b.append(String.format("%02x",v&255));
    return b.toString();
  }
  static String attr(XAttributable x,String key){XAttribute a=x.getAttributes().get(key);return a==null?null:a.toString();}
  static String type(XEvent e,String key){XAttribute a=e.getAttributes().get(key);return a==null?"-":a.getClass().getName();}
  static void observe(String phase,XLog log){
    System.out.println("log\t"+phase+"\t"+hex(attr(log,"concept:name")));
    for(XTrace t:log){
      int c=traces.get(t);
      System.out.println("trace\t"+phase+"\t"+c+"\t"+hex(attr(t,"concept:name")));
      for(XEvent e:t){
        XAttribute ts=e.getAttributes().get("time:timestamp");
        String time=ts instanceof XAttributeTimestamp?Long.toString(((XAttributeTimestamp)ts).getValueMillis()):"-";
        System.out.println("event\t"+phase+"\t"+c+"\t"+events.get(e)+"\t"+hex(attr(e,"concept:name"))+"\t"+hex(attr(e,"lifecycle:transition"))+"\t"+time+"\t"+type(e,"time:timestamp")+"\t"+hex(attr(e,"time:timestamp"))+"\t"+type(e,"concept:name")+"\t"+type(e,"lifecycle:transition"));
      }
    }
  }
  public static void main(String[] args)throws Exception{
    try(InputStream in=new FileInputStream(args[0])){
      List<XLog> logs=new XesXmlParser(new XFactoryNaiveImpl()).parse(in);
      if(logs.size()!=1)throw new IllegalStateException("Expected one XLog");
      XLog log=logs.get(0);
      for(int c=0;c<log.size();c++){
        XTrace t=log.get(c);traces.put(t,c);
        for(int i=0;i<t.size();i++)events.put(t.get(i),i);
      }
      observe("before",log);
      XLog first=ExtractedServiceMethods.validateLog(log);
      System.out.println("same_log\t"+(first==log));
      observe("after",first);
      XLog second=ExtractedServiceMethods.validateLog(first);
      observe("second",second);
    }
  }
}
