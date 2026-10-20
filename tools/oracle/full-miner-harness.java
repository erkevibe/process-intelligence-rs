// Own observer of the actual unchanged canonical SplitMiner and BPMN exporter.
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import org.deckfour.xes.classification.XEventNameClassifier;
import org.deckfour.xes.in.XesXmlParser;
import org.deckfour.xes.factory.XFactoryRegistry;
import org.deckfour.xes.model.XLog;
import org.apromore.splitminer.SplitMiner;
import org.apromore.splitminer.ui.dfgp.DFGPUIResult;
import org.apromore.splitminer.ui.miner.SplitMinerUIResult;
import org.apromore.processmining.models.graphbased.directed.bpmn.*;
import org.apromore.processmining.models.graphbased.directed.bpmn.elements.*;
import org.apromore.processmining.plugins.bpmn.plugins.BpmnExportPlugin;

final class FullMinerHarness {
    static Map<String,Object> obj(Object... pairs) {
        Map<String,Object> map=new LinkedHashMap<>();
        for(int i=0;i<pairs.length;i+=2)map.put((String)pairs[i],pairs[i+1]);
        return map;
    }
    static String sha(byte[] bytes)throws Exception {
        StringBuilder out=new StringBuilder();
        for(byte b:MessageDigest.getInstance("SHA-256").digest(bytes))out.append(String.format("%02x",b&255));
        return out.toString();
    }
    static Map<String,Object> graph(BPMNDiagram diagram) {
        List<Map<String,Object>> nodes=new ArrayList<>(),flows=new ArrayList<>();
        for(BPMNNode node:diagram.getNodes()) {
            Map<String,Object> n=obj("id",node.getId().toString(),"label",node.getLabel(),"class",node.getClass().getName());
            if(node instanceof Gateway)n.put("gateway_type",((Gateway)node).getGatewayType().toString());
            if(node instanceof Event) {
                Event e=(Event)node;
                n.put("event_type",e.getEventType().toString());
                n.put("event_trigger",e.getEventTrigger()==null?null:e.getEventTrigger().toString());
                n.put("event_use",e.getEventUse()==null?null:e.getEventUse().toString());
            }
            if(node instanceof Activity)n.put("looped",((Activity)node).isBLooped());
            nodes.add(n);
        }
        nodes.sort(Comparator.comparing(n->(String)n.get("id")));
        for(Flow flow:diagram.getFlows())flows.add(obj("id",flow.getEdgeID().toString(),"source",flow.getSource().getId().toString(),"target",flow.getTarget().getId().toString(),"label",flow.getLabel(),"condition",flow.getConditionExpression()));
        flows.sort(Comparator.comparing(f->(String)f.get("id")));
        return obj("label",diagram.getLabel(),"nodes",nodes,"flows",flows);
    }
    public static void main(String[] args)throws Exception {
        if(args.length!=3)throw new IllegalArgumentException("input.xes output.json output.bpmn");
        Path input=Path.of(args[0]),json=Path.of(args[1]),bpmn=Path.of(args[2]);
        if(Files.exists(json)||Files.exists(bpmn))throw new IllegalArgumentException("new outputs required");
        byte[] data=Files.readAllBytes(input);
        Map<String,Object> out=obj("schema_version",1,"input_sha256",sha(data),
            "algorithm_class",SplitMiner.class.getName(),
            "algorithm_class_sha256",sha(SplitMiner.class.getResourceAsStream("SplitMiner.class").readAllBytes()),
            "algorithm_code_source",SplitMiner.class.getProtectionDomain().getCodeSource().getLocation().toString(),
            "assertions_enabled",FullMinerHarness.class.desiredAssertionStatus(),
            "factory",XFactoryRegistry.instance().currentDefault().getClass().getName(),
            "parser",XesXmlParser.class.getName(),
            "parameters",obj("percentile_frequency_threshold",.40,"parallelisms_threshold",.10,"filter_type","WTH","parallelisms_first",false,"replace_iors",true,"remove_loop_activities",false,"structuring_time","NONE","classifier",XEventNameClassifier.class.getName()));
        List<XLog> logs=new XesXmlParser().parse(new java.io.ByteArrayInputStream(data));
        if(logs.size()!=1)throw new IllegalStateException("exact one trusted log required");
        XLog log=logs.get(0);
        out.put("input_traces",log.size());
        out.put("input_events",log.stream().mapToInt(t->t.size()).sum());
        SplitMiner miner=new SplitMiner();
        long begin=System.nanoTime();
        BPMNDiagram diagram;
        try {
            diagram=miner.mineBPMNModel(log,new XEventNameClassifier(),.40,.10,DFGPUIResult.FilterType.WTH,false,true,false,SplitMinerUIResult.StructuringTime.NONE);
        } catch(Exception e) {
            out.put("elapsed_mining_nanos",System.nanoTime()-begin);
            out.put("status","algorithm_exception");
            out.put("exception",obj("class",e.getClass().getName(),"message",e.getMessage()));
            Files.write(json,new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsBytes(out),StandardOpenOption.CREATE_NEW);
            return;
        }
        out.put("elapsed_mining_nanos",System.nanoTime()-begin);
        out.put("returned_same_as_miner_field",diagram==miner.getBPMNDiagram());
        out.put("fallback_observation_policy","Native logs preserve internal safe-DFGP attempts; returned identity alone does not prove no safe fallback");
        if(diagram==null)out.put("status","null_diagram");
        else {
            out.put("status",diagram==miner.getBPMNDiagram()?"diagram_returned":"bare_dfg_fallback_returned");
            out.put("graph",graph(diagram));
            new BpmnExportPlugin().export(diagram,bpmn.toFile());
            if(!Files.isRegularFile(bpmn)||Files.size(bpmn)==0)throw new IllegalStateException("actual upstream exporter did not write BPMN");
            out.put("bpmn_sha256",sha(Files.readAllBytes(bpmn)));
            out.put("bpmn_bytes",Files.size(bpmn));
            out.put("exporter",BpmnExportPlugin.class.getName());
        }
        Files.write(json,new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsBytes(out),StandardOpenOption.CREATE_NEW);
    }
}
