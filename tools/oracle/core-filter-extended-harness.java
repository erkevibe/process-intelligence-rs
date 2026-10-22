// Own observer/wiring of actual unchanged Core API. No predicate is implemented here.
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import org.apromore.apmlog.*;
import org.apromore.apmlog.exceptions.EmptyInputException;
import org.apromore.apmlog.filter.*;
import org.apromore.apmlog.filter.rules.*;
import org.apromore.apmlog.filter.typefilters.CaseLengthFilter;
import org.apromore.apmlog.filter.types.*;
import org.apromore.apmlog.logobjects.ActivityInstance;
import org.apromore.apmlog.xes.XLogToImmutableLog;
import org.deckfour.xes.factory.*;
import org.deckfour.xes.model.*;

final class CoreFilterExtendedHarness {
    static final ObjectMapper JSON=new ObjectMapper();
    static Map<String,Object> obj(Object... p){return CoreFilterExtendedXesObserver.object(p);}
    static String hash(Object value)throws Exception{return CoreFilterExtendedXesObserver.sha(JSON.writeValueAsBytes(value));}
    static Map<String,Object> identity(Class<?> c)throws Exception {
        try(InputStream input=c.getResourceAsStream('/'+c.getName().replace('.','/')+".class")){
            return obj("class",c.getName(),"sha256",CoreFilterExtendedXesObserver.sha(input.readAllBytes()),
                "code_source",c.getProtectionDomain().getCodeSource().getLocation().toString());
        }
    }
    static Map<String,Object> failure(Throwable error){
        List<Map<String,Object>> chain=new ArrayList<>();Set<Throwable> seen=Collections.newSetFromMap(new IdentityHashMap<>());
        while(error!=null&&seen.add(error)){chain.add(obj("class",error.getClass().getName(),"message",error.getMessage()));error=error.getCause();}
        return obj("chain",chain,"root",chain.get(chain.size()-1));
    }
    static Map<String,Object> apmSnapshot(APMLog log){
        List<Map<String,Object>> traces=new ArrayList<>();
        for(ATrace trace:log.getTraces()){
            List<Map<String,Object>> activities=new ArrayList<>();
            for(ActivityInstance activity:trace.getActivityInstances())activities.add(obj(
                "immutable_index",activity.getImmutableIndex(),"immutable_trace_index",activity.getImmutableTraceIndex(),
                "mutable_trace_index",activity.getMutableTraceIndex(),"parent_case_id",activity.getParentTraceId(),
                "event_indices",new ArrayList<>(activity.getImmutableEventIndexes()),"name",activity.getName(),
                "name_indicator",activity.getNameIndicator(),"start_time_ms",activity.getStartTime(),"end_time_ms",activity.getEndTime(),
                "attributes",new TreeMap<>(activity.getAttributes())));
            traces.add(obj("immutable_index",trace.getImmutableIndex(),"case_id",trace.getCaseId(),
                "immutable_event_count",trace.getImmutableEvents().size(),"attributes",new TreeMap<>(trace.getAttributes()),"activities",activities));
        }
        return obj("log_name",log.getLogName(),"traces",traces);
    }
    static XLog sourceXLog(Map<String,Object> source,XFactory factory)throws Exception {
        XLog log=factory.createLog();
        log.getAttributes().put("concept:name",factory.createAttributeLiteral("concept:name",(String)source.get("name"),null));
        log.getAttributes().put("source:warnings",factory.createAttributeLiteral("source:warnings",JSON.writeValueAsString(source.get("warnings")),null));
        Set<String> ids=new HashSet<>(),names=new HashSet<>();
        List<?> cases=(List<?>)source.get("cases");
        if(cases.size()>100)throw new IllegalArgumentException("source case cap");
        for(Object raw:cases){
            Map<String,Object> c=(Map<String,Object>)raw;
            if(!c.keySet().equals(Set.of("id","name","events"))||!ids.add((String)c.get("id"))||!names.add((String)c.get("name")))throw new IllegalArgumentException("exact source case keys/unique IDs/names");
            XTrace trace=factory.createTrace();
            trace.getAttributes().put("concept:name",factory.createAttributeLiteral("concept:name",(String)c.get("name"),null));
            trace.getAttributes().put("case:source_id",factory.createAttributeLiteral("case:source_id",(String)c.get("id"),null));
            List<?> events=(List<?>)c.get("events");if(events.isEmpty()||events.size()>1000)throw new IllegalArgumentException("nonempty finite source trace");
            for(Object item:events){
                Map<String,Object> e=(Map<String,Object>)item;
                if(!e.keySet().equals(Set.of("ordinal","activity","timestamp","lifecycle"))||!"complete".equals(e.get("lifecycle")))throw new IllegalArgumentException("exact complete source event");
                XEvent event=factory.createEvent();
                event.getAttributes().put("concept:name",factory.createAttributeLiteral("concept:name",(String)e.get("activity"),null));
                event.getAttributes().put("lifecycle:transition",factory.createAttributeLiteral("lifecycle:transition",(String)e.get("lifecycle"),null));
                event.getAttributes().put("time:timestamp",factory.createAttributeTimestamp("time:timestamp",Date.from(Instant.parse((String)e.get("timestamp"))),null));
                event.getAttributes().put("event:source_ordinal",factory.createAttributeDiscrete("event:source_ordinal",((Number)e.get("ordinal")).longValue(),null));
                trace.add(event);
            }
            log.add(trace);
        }
        return log;
    }
    public static void main(String[] args)throws Exception {
        if(args.length!=2)throw new IllegalArgumentException("frozen-case.json NEW-observation.json");
        Path path=Path.of(args[0]),output=Path.of(args[1]);
        if(Files.size(path)>1024*1024||Files.exists(output))throw new IllegalArgumentException("bounded frozen input/fresh output");
        byte[] bytes=Files.readAllBytes(path);Map<String,Object> input=JSON.readValue(bytes,Map.class);
        if(!input.keySet().equals(Set.of("schema_version","id","filter_spec","source"))||!Integer.valueOf(1).equals(input.get("schema_version")))throw new IllegalArgumentException("exact input ABI");
        Map<String,Object> source=(Map<String,Object>)input.get("source");
        if(!source.keySet().equals(Set.of("name","cases","warnings")))throw new IllegalArgumentException("exact EventLog shape");
        Map<String,Object> spec=(Map<String,Object>)input.get("filter_spec");
        if(!spec.keySet().equals(Set.of("case_activity","min_events","max_events","retain_activities","remove_activities"))||spec.get("case_activity")!=null)throw new IllegalArgumentException("exact admitted FilterSpec profile");
        List<String> retain=(List<String>)spec.get("retain_activities"),remove=(List<String>)spec.get("remove_activities");
        if(retain.size()>100||remove.size()>100)throw new IllegalArgumentException("finite attribute values");
        for(String value:retain)if(value.getBytes(StandardCharsets.UTF_8).length>4096)throw new IllegalArgumentException("finite literal");
        for(String value:remove)if(value.getBytes(StandardCharsets.UTF_8).length>4096)throw new IllegalArgumentException("finite literal");
        for(String key:List.of("min_events","max_events"))if(spec.get(key)!=null&&(((Number)spec.get(key)).longValue()<0||((Number)spec.get(key)).longValue()>10000))throw new IllegalArgumentException("finite fixture length boundary");
        Map<String,Object> engineIdentity=identity(APMLogFilter.class),predicateIdentity=identity(CaseLengthFilter.class);
        if(!engineIdentity.get("sha256").equals("b07c241d7d5a430f9fd1f6cea5eb696a71eefdee7dc268ee0c81d18c464769b3")||!predicateIdentity.get("sha256").equals("1409e5c3cf4e730cf33eae022fc159a29c557eb98106849523ddd1e0f86c64be"))throw new IllegalStateException("actual unchanged original classes required");
        XFactory factory=XFactoryRegistry.instance().currentDefault();XLog xlog=sourceXLog(source,factory);
        Map<String,Object> beforeXes=CoreFilterExtendedXesObserver.log(xlog);
        Map<String,Object> result=obj("schema_version",1,"id",input.get("id"),"input_sha256",CoreFilterExtendedXesObserver.sha(bytes),
            "engine_identity",engineIdentity,"case_length_identity",predicateIdentity,"converter_identity",identity(XLogToImmutableLog.class),
            "rule_identity",identity(LogFilterRuleImpl.class),"rule_value_identity",identity(RuleValue.class),
            "factory",factory.getClass().getName(),"assertions_enabled",CoreFilterExtendedHarness.class.desiredAssertionStatus(),
            "filter_spec",spec,"one_java_ordered_rule_list",true,
            "source_domain_before",source,"source_domain_before_sha256",hash(source),"source_xlog_before",beforeXes,"source_xlog_before_sha256",hash(beforeXes),"engine_invoked",false);
        APMLog apm;
        try{apm=XLogToImmutableLog.convertXLog((String)source.get("name"),xlog);}
        catch(EmptyInputException e){
            result.put("status","converter_refused");result.put("outcome","converter_refused");result.put("exception",failure(e));
            Map<String,Object> after=CoreFilterExtendedXesObserver.log(xlog);
            result.put("source_xlog_after_conversion",after);result.put("source_xlog_after_conversion_sha256",hash(after));
            result.put("source_domain_after",source);result.put("source_domain_after_sha256",hash(source));
            Files.write(output,JSON.writerWithDefaultPrettyPrinter().writeValueAsBytes(result),StandardOpenOption.CREATE_NEW);return;
        }
        Map<String,Object> afterConversion=CoreFilterExtendedXesObserver.log(xlog),beforeApm=apmSnapshot(apm);
        result.put("source_xlog_after_conversion",afterConversion);result.put("source_xlog_after_conversion_sha256",hash(afterConversion));
        result.put("source_apm_before",beforeApm);result.put("source_apm_before_sha256",hash(beforeApm));
        List<LogFilterRule> rules=new ArrayList<>();
        if(spec.get("min_events")!=null||spec.get("max_events")!=null){
            long lower=spec.get("min_events")==null?0:((Number)spec.get("min_events")).longValue();
            long upper=spec.get("max_events")==null?Long.MAX_VALUE:((Number)spec.get("max_events")).longValue();
            Set<RuleValue> values=new LinkedHashSet<>();
            values.add(new RuleValue(FilterType.CASE_LENGTH,OperationType.GREATER_EQUAL,"case:length",Long.valueOf(lower)));
            values.add(new RuleValue(FilterType.CASE_LENGTH,OperationType.LESS_EQUAL,"case:length",Long.valueOf(upper)));
            rules.add(new LogFilterRuleImpl(Choice.RETAIN,Inclusion.ANY_VALUE,Section.CASE,FilterType.CASE_LENGTH,"case:length",values,null));
        }
        for(Choice choice:List.of(Choice.RETAIN,Choice.REMOVE)){
            List<String> literals=choice==Choice.RETAIN?retain:remove;
            if(!literals.isEmpty()){
                RuleValue value=new RuleValue(FilterType.EVENT_EVENT_ATTRIBUTE,OperationType.EQUAL,"concept:name",new LinkedHashSet<>(literals));
                rules.add(new LogFilterRuleImpl(choice,Inclusion.ANY_VALUE,Section.EVENT,FilterType.EVENT_EVENT_ATTRIBUTE,"concept:name",Set.of(value),null));
            }
        }
        List<Map<String,Object>> actualRules=new ArrayList<>();
        for(LogFilterRule rule:rules){
            List<Map<String,Object>> values=new ArrayList<>();
            for(RuleValue value:rule.getPrimaryValues())values.add(obj("operation",value.getOperationType().name(),"long_value",rule.getFilterType()==FilterType.CASE_LENGTH?value.getLongValue():null,"string_set",rule.getFilterType()==FilterType.EVENT_EVENT_ATTRIBUTE?new ArrayList<>(value.getStringSetValue()):null));
            actualRules.add(obj("filter_type",rule.getFilterType().name(),"choice",rule.getChoice().name(),"section",rule.getSection().name(),"inclusion",rule.getInclusion().name(),"key",rule.getKey(),"primary_values",values));
        }
        result.put("java_ordered_rules",actualRules);
        APMLogFilter engine=new APMLogFilter(apm);result.put("engine_invoked",true);result.put("engine_call_count",1);
        PLog selected=engine.filterIndex(rules);
        List<List<Integer>> positions=new ArrayList<>();List<Integer> indices=new ArrayList<>();List<Map<String,Object>> pointers=new ArrayList<>();List<Object> selectedCases=new ArrayList<>();
        List<?> sourceCases=(List<?>)source.get("cases");
        for(PTrace trace:selected.getPTraces()){
            int index=trace.getImmutableIndex();
            if(index<0||index>=sourceCases.size()||indices.contains(index))throw new IllegalStateException("actual unique immutable source index");
            Map<String,Object> original=(Map<String,Object>)sourceCases.get(index);
            if(!trace.getCaseId().equals(original.get("name"))||!trace.getAttributes().get("case:source_id").equals(original.get("id")))throw new IllegalStateException("actual index/source identity binding");
            List<Integer> eventIndices=new ArrayList<>();
            for(int e=trace.getValidEventIndexBS().nextSetBit(0);e>=0;e=trace.getValidEventIndexBS().nextSetBit(e+1))eventIndices.add(e);
            int sourceEventCount=((List<?>)original.get("events")).size();
            List<Object> projectedEvents=new ArrayList<>();
            for(int eventIndex:eventIndices){
                if(eventIndex<0||eventIndex>=sourceEventCount)throw new IllegalStateException("actual returned event index/source bound");
                projectedEvents.add(((List<?>)original.get("events")).get(eventIndex));
            }
            Map<String,Object> projected=new LinkedHashMap<>(original);projected.put("events",projectedEvents);
            indices.add(index);positions.add(eventIndices);selectedCases.add(projected);
            pointers.add(obj("immutable_trace_index",index,"mutable_pointer_index",trace.getMutableIndex(),"case_id",trace.getCaseId(),
                "source_case_id",original.get("id"),"valid_event_indices",eventIndices,"stored_activity_instance_count",trace.getActivityInstances().size()));
        }
        Map<String,Object> afterApm=apmSnapshot(apm),afterXes=CoreFilterExtendedXesObserver.log(xlog);
        result.put("status","filtered");result.put("outcome","filtered");result.put("selected_source_indices",indices);result.put("selected_event_positions",positions);result.put("selected_pointer_traces",pointers);
        result.put("selected_source_log",obj("name",source.get("name"),"cases",selectedCases,"warnings",source.get("warnings")));
        result.put("source_apm_after",afterApm);result.put("source_apm_after_sha256",hash(afterApm));
        result.put("source_xlog_after_filter",afterXes);result.put("source_xlog_after_filter_sha256",hash(afterXes));
        result.put("source_domain_after",source);result.put("source_domain_after_sha256",hash(source));
        result.put("selection_observation","Source cases/events projected only by actual returned PTrace immutable indexes and valid-event BitSet; no observer predicate or APM-to-XES export");
        Files.write(output,JSON.writerWithDefaultPrettyPrinter().writeValueAsBytes(result),StandardOpenOption.CREATE_NEW);
    }
}
