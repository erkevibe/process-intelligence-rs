// Own observation of unchanged original CalendarModel; no duration algorithm here.
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.InputStream;
import java.nio.file.*;
import java.security.MessageDigest;
import java.time.*;
import java.time.zone.ZoneRulesProvider;
import java.util.*;
import org.apromore.calendar.builder.CalendarModelBuilder;
import org.apromore.calendar.model.*;

final class CoreCalendarHarness {
    static final ObjectMapper JSON=new ObjectMapper();
    static Map<String,Object> obj(Object... pairs){Map<String,Object> value=new LinkedHashMap<>();for(int i=0;i<pairs.length;i+=2)value.put((String)pairs[i],pairs[i+1]);return value;}
    static String sha(byte[] bytes)throws Exception {StringBuilder value=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(bytes))value.append(String.format("%02x",b&255));return value.toString();}
    static String hash(Object value)throws Exception{return sha(JSON.writeValueAsBytes(value));}
    static Map<String,Object> identity(Class<?> c)throws Exception {
        try(InputStream in=c.getResourceAsStream('/'+c.getName().replace('.','/')+".class")){
            return obj("class",c.getName(),"sha256",sha(in.readAllBytes()),"code_source",c.getProtectionDomain().getCodeSource().getLocation().toString());
        }
    }
    static Map<String,Object> failure(Throwable e){List<Map<String,Object>> chain=new ArrayList<>();Set<Throwable> seen=Collections.newSetFromMap(new IdentityHashMap<>());while(e!=null&&seen.add(e)){chain.add(obj("class",e.getClass().getName(),"message",e.getMessage()));e=e.getCause();}return obj("chain",chain,"root",chain.get(chain.size()-1));}
    static Map<String,Object> configuration(CalendarModel model){
        List<Map<String,Object>> days=new ArrayList<>(),holidays=new ArrayList<>();
        for(WorkDayModel day:model.getWorkDays())days.add(obj("weekday",day.getDayOfWeek().getValue(),"start_time",day.getStartTime().toString(),"end_time",day.getEndTime().toString(),"working_day",day.isWorkingDay(),"id",day.getId(),"created_by",day.getCreatedBy(),"updated_by",day.getUpdatedBy()));
        for(HolidayModel holiday:model.getHolidays())holidays.add(obj("type",holiday.getHolidayType().name(),"date",holiday.getHolidayDate().toString(),"name",holiday.getName(),"description",holiday.getDescription(),"id",holiday.getId(),"created_by",holiday.getCreatedBy(),"updated_by",holiday.getUpdatedBy()));
        return obj("zone_id",model.getZoneId(),"work_days",days,"holidays",holidays,"id",model.getId(),"name",model.getName(),"created",model.getCreated().toString(),"updated",model.getUpdated().toString(),"created_by",model.getCreatedBy(),"updated_by",model.getUpdatedBy());
    }
    static void save(Path output,Map<String,Object> result,Map<String,Object> input)throws Exception{
        result.put("source_input_after",input);result.put("source_input_after_sha256",hash(input));
        Files.write(output,JSON.writerWithDefaultPrettyPrinter().writeValueAsBytes(result),StandardOpenOption.CREATE_NEW);
    }
    public static void main(String[] args)throws Exception{
        if(args.length!=2)throw new IllegalArgumentException("frozen-input.json NEW-observation.json");
        Path path=Path.of(args[0]),output=Path.of(args[1]);
        if(Files.size(path)>1024*1024||Files.exists(output))throw new IllegalArgumentException("bounded input/fresh output");
        byte[] bytes=Files.readAllBytes(path);Map<String,Object> input=JSON.readValue(bytes,Map.class);
        if(!input.keySet().equals(Set.of("schema_version","id","start","end","calendar"))||!Integer.valueOf(1).equals(input.get("schema_version")))throw new IllegalArgumentException("exact frozen ABI");
        Map<String,Object> spec=(Map<String,Object>)input.get("calendar");
        if(!spec.keySet().equals(Set.of("offset_minutes","timezone","weekdays","start_minute","end_minute","holidays"))||((Number)spec.get("offset_minutes")).intValue()!=0)throw new IllegalArgumentException("named-zone fixture ABI");
        String zone=(String)spec.get("timezone");List<Number> weekdays=(List<Number>)spec.get("weekdays");List<String> holidays=(List<String>)spec.get("holidays");
        int opening=((Number)spec.get("start_minute")).intValue(),closing=((Number)spec.get("end_minute")).intValue();
        if(zone.length()>128||weekdays.size()>7||holidays.size()>3660||opening<0||opening>=1440||closing<0||closing>=1440)throw new IllegalArgumentException("finite same-day fixture representation; overnight order deliberately not validated");
        Instant start=Instant.parse((String)input.get("start")),end=Instant.parse((String)input.get("end"));
        Map<String,Object> calendarIdentity=identity(CalendarModel.class),workdayIdentity=identity(WorkDayModel.class),builderIdentity=identity(CalendarModelBuilder.class);
        if(!calendarIdentity.get("sha256").equals("875c96a343e48cdc42c613b5f65ba7b35056498e112ebffd865084c4ad8c1e39")||!workdayIdentity.get("sha256").equals("e9983bdef6b0fe12f0d7db7bb03c326fdb1259a69cdf34bb8e0d279bb3217207")||!builderIdentity.get("sha256").equals("8e2fefee2d943e7e8864d80d9cdfdaf8ce42ebb18e3002639d449a31c81096c5"))throw new IllegalStateException("unchanged canonical calendar classes required");
        Map<String,Object> result=obj("schema_version",1,"id",input.get("id"),"input_sha256",sha(bytes),"engine","org.apromore.calendar.model.CalendarModel","calendar_identity",calendarIdentity,"workday_identity",workdayIdentity,"builder_identity",builderIdentity,"factory_identity",identity(Calendars.class),"source_input_before",input,"source_input_before_sha256",hash(input),"configuration_available",false,"configuration_unchanged",null,"configuration_before",null,"configuration_after",null,"java_zone_rules_versions",null,"duration_millis",null,"duration_seconds",null,"duration_nanos",null,"get_duration_millis_secondary",null,"duration_method_invoked",false,"secondary_method_invoked",false,"assertions_enabled",CoreCalendarHarness.class.desiredAssertionStatus(),"main_method","getDuration(Instant,Instant).toMillis()","secondary_method","getDurationMillis(Instant,Instant)");
        CalendarModelBuilder builder=new CalendarModelBuilder();
        try{builder.withZoneId(zone);}catch(DateTimeException e){result.put("outcome","builder_refused");result.put("exception_stage","CalendarModelBuilder.withZoneId");result.put("exception",failure(e));save(output,result,input);return;}
        for(Number day:weekdays)builder.withWorkDay(DayOfWeek.of(day.intValue()),LocalTime.of(opening/60,opening%60),LocalTime.of(closing/60,closing%60),true);
        for(String holiday:holidays)builder.withHoliday(HolidayType.PUBLIC,"fixture-holiday","own synthetic frozen date",LocalDate.parse(holiday));
        CalendarModel model=builder.build();result.put("configuration_available",true);
        Map<String,Object> before=configuration(model);result.put("configuration_before",before);result.put("configuration_before_sha256",hash(before));
        try{result.put("java_zone_rules_versions",new ArrayList<>(ZoneRulesProvider.getVersions(zone).keySet()));}catch(DateTimeException e){result.put("java_zone_rules_versions",null);result.put("zone_rules_observation_exception",failure(e));}
        result.put("local_start",ZonedDateTime.ofInstant(start,ZoneId.of(zone)).toString());result.put("local_end",ZonedDateTime.ofInstant(end,ZoneId.of(zone)).toString());
        try{
            result.put("duration_method_invoked",true);Duration duration=model.getDuration(start,end);
            result.put("outcome","duration");result.put("duration_seconds",duration.getSeconds());result.put("duration_nanos",duration.getNano());result.put("duration_millis",duration.toMillis());
            Map<String,Object> afterMain=configuration(model);result.put("configuration_after_main",afterMain);result.put("configuration_after_main_sha256",hash(afterMain));
            result.put("secondary_method_invoked",true);result.put("get_duration_millis_secondary",model.getDurationMillis(start,end));
        }catch(RuntimeException e){result.put("outcome","duration_refused");result.put("exception_stage",Boolean.TRUE.equals(result.get("secondary_method_invoked"))?"CalendarModel.getDurationMillis":"CalendarModel.getDuration");result.put("exception",failure(e));}
        Map<String,Object> after=configuration(model);result.put("configuration_after",after);result.put("configuration_after_sha256",hash(after));result.put("configuration_unchanged",before.equals(after));
        save(output,result,input);
    }
}
