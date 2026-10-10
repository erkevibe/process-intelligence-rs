// Original adapter. Calls unchanged pinned Apromore LogParser text overload.
import org.apromore.splitminer.log.LogParser;
import org.apromore.splitminer.log.SimpleLog;
import java.util.*;
public final class LegacyHarness {
 public static void main(String[] args) {
  SimpleLog log=LogParser.getSimpleLog(args[0]);
  if(log==null) throw new IllegalStateException("Reference parser failed");
  System.out.println("cases\t"+log.size());
  System.out.println("activities\t"+log.getDistinctEvents());
  System.out.println("raw_total_events\t"+log.getTotalEvents());
  for(Map.Entry<String,Integer> e:new TreeMap<>(log.getTraces()).entrySet()) {
   List<String> labels=new ArrayList<>();
   for(String code:e.getKey().split(":")) if(!code.isEmpty()) {
    int id=Integer.parseInt(code); if(id!=log.getStartcode()&&id!=log.getEndcode()) labels.add(log.getEvents().get(id));
   }
   System.out.println("variant\t"+e.getValue()+"\t"+String.join(",",labels));
  }
 }
}
