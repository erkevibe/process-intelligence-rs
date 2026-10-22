// Own benchmark wiring only. The original SplitMiner/parser/exporter are unchanged.
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.lang.management.*;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import org.deckfour.xes.classification.XEventNameClassifier;
import org.deckfour.xes.factory.XFactoryRegistry;
import org.deckfour.xes.in.XesXmlParser;
import org.deckfour.xes.model.XLog;
import org.apromore.splitminer.SplitMiner;
import org.apromore.splitminer.ui.dfgp.DFGPUIResult;
import org.apromore.splitminer.ui.miner.SplitMinerUIResult;
import org.apromore.processmining.models.graphbased.directed.bpmn.*;
import org.apromore.processmining.models.graphbased.directed.bpmn.elements.*;
import org.apromore.processmining.plugins.bpmn.plugins.BpmnExportPlugin;

final class SplitMinerBenchmarkHarness {
    // No static object/parser/miner initialization before the first GO gate.
    static Map<String,Object> obj(Object... pairs){Map<String,Object> m=new LinkedHashMap<>();for(int i=0;i<pairs.length;i+=2)m.put((String)pairs[i],pairs[i+1]);return m;}
    static String sha(byte[] bytes)throws Exception{StringBuilder s=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(bytes))s.append(String.format("%02x",b&255));return s.toString();}
    static String hash(ObjectMapper json,Object value)throws Exception{return sha(json.writeValueAsBytes(value));}
    static String readLine(InputStream stream)throws IOException{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        for(int i=0;i<512;i++){int b=stream.read();if(b<0)throw new EOFException("protocol EOF");if(b=='\n'){byte[] value=bytes.toByteArray();int length=value.length;if(length>0&&value[length-1]=='\r')length--;return new String(value,0,length,StandardCharsets.US_ASCII);}if(b>127)throw new IOException("protocol ASCII required");bytes.write(b);}
        throw new IOException("protocol line cap");
    }
    static void protocol(String phase,long pid,String nonce,String process){
        System.out.println("S20_PROTOCOL {\"phase\":\""+phase+"\",\"pid\":"+pid+",\"nonce\":\""+nonce+"\",\"process_id\":\""+process+"\"}");System.out.flush();
    }
    static Map<String,Object> identity(Class<?> c)throws Exception{
        try(InputStream in=c.getResourceAsStream('/'+c.getName().replace('.','/')+".class")){return obj("class",c.getName(),"sha256",sha(in.readAllBytes()),"code_source",c.getProtectionDomain().getCodeSource().getLocation().toString());}
    }
    static Map<String,Object> failure(Exception error){
        List<Map<String,Object>> chain=new ArrayList<>();Set<Throwable> seen=Collections.newSetFromMap(new IdentityHashMap<>());Throwable e=error;
        while(e!=null&&seen.add(e)&&chain.size()<32){List<Map<String,Object>> suppressed=new ArrayList<>();for(Throwable s:e.getSuppressed()){if(suppressed.size()>=32)break;suppressed.add(obj("class",s.getClass().getName(),"message",s.getMessage()));}chain.add(obj("class",e.getClass().getName(),"message",e.getMessage(),"suppressed",suppressed));e=e.getCause();}
        return obj("chain",chain,"root",chain.get(chain.size()-1),"cause_chain_truncated",e!=null);
    }
    static void force(Path path)throws IOException{try(FileChannel channel=FileChannel.open(path,StandardOpenOption.WRITE)){channel.force(true);}}
    static Map<String,Object> write(ObjectMapper json,Path path,Object value,long limit)throws Exception{
        byte[] bytes=json.writerWithDefaultPrettyPrinter().writeValueAsBytes(value);if(bytes.length>limit)throw new IOException("bounded JSON artifact cap");
        Files.write(path,bytes,StandardOpenOption.CREATE_NEW);force(path);return obj("file",path.getFileName().toString(),"sha256",sha(bytes),"bytes",bytes.length);
    }
    static void ledger(ObjectMapper json,FileOutputStream stream,Object value)throws Exception{
        byte[] bytes=json.writeValueAsBytes(value);if(bytes.length>16384)throw new IOException("ledger line cap");stream.write(bytes);stream.write('\n');stream.flush();stream.getChannel().force(true);
    }
    static Map<String,Object> gc(){List<Map<String,Object>> out=new ArrayList<>();for(GarbageCollectorMXBean b:ManagementFactory.getGarbageCollectorMXBeans())out.add(obj("name",b.getName(),"collection_count",b.getCollectionCount(),"collection_time_millis",b.getCollectionTime()));return obj("collectors",out,"unsupported_negative_values_preserved",true);}
    static Map<String,Object> safeGC(){try{return gc();}catch(RuntimeException error){return obj("diagnostic_exception",failure(error));}}
    static Map<String,Object> graph(BPMNDiagram diagram){
        List<Map<String,Object>> nodes=new ArrayList<>(),flows=new ArrayList<>();
        for(BPMNNode node:diagram.getNodes()){
            Map<String,Object> n=obj("id",node.getId().toString(),"label",node.getLabel(),"class",node.getClass().getName(),"parent_subprocess",node.getParentSubProcess()==null?null:node.getParentSubProcess().getId().toString());
            if(node instanceof Gateway){Gateway g=(Gateway)node;n.put("gateway_type",g.getGatewayType().toString());n.put("marker_visible",g.isMarkerVisible());}
            if(node instanceof Event){Event e=(Event)node;n.put("event_type",e.getEventType().toString());n.put("event_trigger",e.getEventTrigger()==null?null:e.getEventTrigger().toString());n.put("event_use",e.getEventUse()==null?null:e.getEventUse().toString());n.put("interrupting",e.isInterrupting());n.put("parallel_multiple",e.getParallelMultiple());}
            if(node instanceof Activity){Activity a=(Activity)node;n.put("script",a.isBScript());n.put("service",a.isBService());n.put("receive",a.isBReceive());n.put("send",a.isBSend());n.put("collapsed",a.isBCollapsed());n.put("looped",a.isBLooped());n.put("adhoc",a.isBAdhoc());n.put("compensation",a.isBCompensation());n.put("multiinstance",a.isBMultiinstance());}
            if(node instanceof SubProcess)n.put("triggered_by_event",((SubProcess)node).getTriggeredByEvent());nodes.add(n);
        }
        nodes.sort(Comparator.comparing(n->(String)n.get("id")));
        for(Flow f:diagram.getFlows())flows.add(obj("id",f.getEdgeID().toString(),"source",f.getSource().getId().toString(),"target",f.getTarget().getId().toString(),"label",f.getLabel(),"condition",f.getConditionExpression(),"text_annotation",f.getTextAnnotation(),"parent_subprocess",f.getParentSubProcess()==null?null:f.getParentSubProcess().getId().toString()));
        flows.sort(Comparator.comparing(f->(String)f.get("id")));
        return obj("label",diagram.getLabel(),"nodes",nodes,"flows",flows,"full_exported_semantic_authority","raw BPMN XML; graph fields do not replace full XML bijection");
    }
    public static void main(String[] args)throws Exception{
        if(args.length!=6)throw new IllegalArgumentException("INPUT_XES NEW_RESULTS_DIR PROCESS_ID CASE_ID NONCE cold|warm");
        String process=args[2],caseId=args[3],nonce=args[4],regime=args[5];
        if(!caseId.matches("[a-z][a-z0-9-]{0,39}")||!process.matches("[a-z][a-z0-9-]{0,79}")||!nonce.matches("[A-Za-z0-9-]{16,128}")||!(regime.equals("cold")||regime.equals("warm")))throw new IllegalArgumentException("bounded protocol identity");
        if(regime.equals("warm")?!process.equals("warm-"+caseId):!process.matches("cold-r[1-3]-"+caseId))throw new IllegalArgumentException("frozen process naming");
        long pid=ProcessHandle.current().pid();protocol("BOOT_READY",pid,nonce,process);
        if(!readLine(System.in).equals("GO "+nonce))throw new IOException("first GO nonce mismatch");
        long activeStart=System.nanoTime();
        Path input=Path.of(args[0]),output=Path.of(args[1]);
        if(Files.isSymbolicLink(input)||Files.size(input)>1024*1024)throw new IOException("bounded regular input");
        if(!Files.exists(output))Files.createDirectory(output);
        if(!Files.isDirectory(output)||Files.isSymbolicLink(output))throw new IOException("fresh private result directory required");
        ObjectMapper json=new ObjectMapper();byte[] bytes=Files.readAllBytes(input);String inputSha=sha(bytes);
        Map<String,Object> minerIdentity=identity(SplitMiner.class);
        if(!minerIdentity.get("sha256").equals("e8535a6b65b7e758a49e757d635e8797071b8e860bc8d1c6859e592eb1ee21ad"))throw new IllegalStateException("unchanged real SplitMiner class required");
        Map<String,Object> parameters=obj("percentile_frequency_threshold",.40,"parallelisms_threshold",.10,"filter_type","WTH","parallelisms_first",false,"replace_iors",true,"remove_loop_activities",false,"structuring_time","NONE","classifier",XEventNameClassifier.class.getName());
        Map<String,Object> summary=obj("schema_version",1,"process_id",process,"case_id",caseId,"nonce",nonce,"pid",pid,"regime",regime,"input_sha256",inputSha,"algorithm_identity",minerIdentity,"parser_identity",identity(XesXmlParser.class),"exporter_identity",identity(BpmnExportPlugin.class),"harness_identity",identity(SplitMinerBenchmarkHarness.class),"xes_observer_identity",identity(SplitMinerBenchmarkXesObserver.class),"parameters",parameters,"assertions_enabled",SplitMinerBenchmarkHarness.class.desiredAssertionStatus(),"jvm_arguments",ManagementFactory.getRuntimeMXBean().getInputArguments(),"java_version",System.getProperty("java.version"),"java_vm",System.getProperty("java.vm.name"),"available_processors",Runtime.getRuntime().availableProcessors(),"heap_max_bytes_diagnostic_only",Runtime.getRuntime().maxMemory(),"factory",XFactoryRegistry.instance().currentDefault().getClass().getName(),"started_after_go_utc",Instant.now().toString(),"warm_memory_scope","whole process including warmups/allcalls/parses/exports/observer; never per-call memory","fallback_policy","all original console bytes retained by Root; returned identity alone does not prove absence of internal safe fallback");
        int count=regime.equals("cold")?1:5;List<Map<String,Object>> completed=new ArrayList<>(),artifacts=new ArrayList<>();Path ledgerPath=output.resolve("iteration-ledger.jsonl");
        try(FileOutputStream log=new FileOutputStream(Files.createFile(ledgerPath).toFile(),true)){
            for(int ordinal=1;ordinal<=count;ordinal++){
                boolean warmup=regime.equals("warm")&&ordinal<=2;String call=process+(warmup?"-warmup-"+ordinal:"-measure-"+(regime.equals("cold")?1:ordinal-2));
                ledger(json,log,obj("event","call_started","call_id",call,"ordinal_in_process",ordinal,"role",warmup?"warmup":"measured","input_sha256",inputSha));
                System.out.println("S20_CALL_BEGIN "+call);System.out.flush();
                Map<String,Object> row=obj("schema_version",1,"call_id",call,"process_id",process,"case_id",caseId,"ordinal_in_process",ordinal,"role",warmup?"warmup":"measured","input_sha256",inputSha,"engine_invoked",false,"engine_time_nanos",null,"parse_time_nanos",null,"export_time_nanos",null,"status","not_started");
                String stage="parse";XLog logModel=null;
                try{
                    long parseStart=System.nanoTime();List<XLog> logs=new XesXmlParser().parse(new ByteArrayInputStream(bytes));row.put("parse_time_nanos",System.nanoTime()-parseStart);
                    if(logs.size()!=1)throw new IllegalStateException("exact one trusted XLog required");logModel=logs.get(0);
                    stage="input_observation";Map<String,Object> before=SplitMinerBenchmarkXesObserver.log(logModel);row.put("input_xlog_before",before);row.put("input_xlog_before_sha256",hash(json,before));row.put("input_traces",logModel.size());row.put("input_events",logModel.stream().mapToInt(t->t.size()).sum());
                    stage="miner_construction";SplitMiner miner=new SplitMiner();stage="classifier_construction";XEventNameClassifier classifier=new XEventNameClassifier();BPMNDiagram diagram;
                    row.put("gc_before",safeGC());stage="mine";row.put("engine_invoked",true);long engineStart=System.nanoTime();
                    try{diagram=miner.mineBPMNModel(logModel,classifier,.40,.10,DFGPUIResult.FilterType.WTH,false,true,false,SplitMinerUIResult.StructuringTime.NONE);}finally{row.put("engine_time_nanos",System.nanoTime()-engineStart);row.put("gc_after",safeGC());}
                    row.put("returned_same_as_miner_field",diagram==miner.getBPMNDiagram());
                    if(diagram==null)row.put("status","null_diagram");
                    else{
                        row.put("status",diagram==miner.getBPMNDiagram()?"diagram_returned":"bare_dfg_fallback_returned");stage="graph_observation";row.put("graph",graph(diagram));
                        stage="export";Path bpmn=output.resolve(call+".bpmn");if(Files.exists(bpmn))throw new IOException("fresh BPMN artifact required");long exportStart=System.nanoTime();
                        new BpmnExportPlugin().export(diagram,bpmn.toFile());if(!Files.isRegularFile(bpmn)||Files.size(bpmn)==0||Files.size(bpmn)>1024*1024)throw new IOException("bounded actual exported BPMN required");force(bpmn);row.put("export_time_nanos",System.nanoTime()-exportStart);
                        Map<String,Object> artifact=obj("file",bpmn.getFileName().toString(),"sha256",sha(Files.readAllBytes(bpmn)),"bytes",Files.size(bpmn));row.put("bpmn",artifact);artifacts.add(artifact);
                    }
                }catch(Exception error){row.put("status",stage.equals("mine")?"algorithm_exception":stage+"_exception");row.put("exception_stage",stage);row.put("exception",failure(error));}
                if(logModel!=null){Map<String,Object> after=SplitMinerBenchmarkXesObserver.log(logModel);row.put("input_xlog_after",after);row.put("input_xlog_after_sha256",hash(json,after));row.put("input_xlog_unchanged",row.get("input_xlog_before_sha256")==null?null:row.get("input_xlog_before_sha256").equals(row.get("input_xlog_after_sha256")));}
                Path anyBpmn=output.resolve(call+".bpmn");
                if(!row.containsKey("bpmn")&&Files.isRegularFile(anyBpmn)){
                    long size=Files.size(anyBpmn);Map<String,Object> partial=obj("file",anyBpmn.getFileName().toString(),"bytes",size,"sha256",size<=1024*1024?sha(Files.readAllBytes(anyBpmn)):null,"partial_or_failed_export",true,"over_artifact_cap",size>1024*1024);
                    row.put("partial_bpmn",partial);artifacts.add(partial);
                }
                Map<String,Object> observation=write(json,output.resolve(call+".json"),row,1024*1024);artifacts.add(observation);completed.add(row);
                ledger(json,log,obj("event","call_completed","call_id",call,"status",row.get("status"),"observation",observation));System.out.println("S20_CALL_END "+call);System.out.flush();
            }
        }
        summary.put("scheduled_calls",count);summary.put("completed_calls",completed.size());summary.put("iterations",completed);summary.put("artifacts",artifacts);summary.put("ledger",obj("file",ledgerPath.getFileName().toString(),"sha256",sha(Files.readAllBytes(ledgerPath)),"bytes",Files.size(ledgerPath)));summary.put("active_work_before_summary_nanos",System.nanoTime()-activeStart);
        Map<String,Object> summaryArtifact=write(json,output.resolve("summary.json"),summary,8*1024*1024);
        Map<String,Object> terminal=obj("schema_version",1,"phase","TERMINAL_READY","pid",pid,"nonce",nonce,"process_id",process,"scheduled_calls",count,"completed_calls",completed.size(),"summary",summaryArtifact,"ledger",summary.get("ledger"),"active_pipeline_nanos",System.nanoTime()-activeStart,"pipeline_boundary","after accepted GO through all benchmark outputs/summary force; terminal-control metadata writer excluded");
        Map<String,Object> readyArtifact=write(json,output.resolve("terminal-ready.json"),terminal,16384);
        System.out.println("S20_PROTOCOL "+json.writeValueAsString(obj("phase","TERMINAL_READY","pid",pid,"nonce",nonce,"process_id",process,"terminal_ready",readyArtifact,"summary",summaryArtifact,"ledger",summary.get("ledger"),"scheduled_calls",count,"completed_calls",completed.size())));System.out.flush();
        if(!readLine(System.in).equals("EXIT "+nonce))throw new IOException("terminal EXIT nonce mismatch");
    }
}
