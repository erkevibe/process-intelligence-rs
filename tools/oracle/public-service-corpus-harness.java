// Own scenario runner/observer; delegates every business operation to original beans.
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import org.apromore.dao.*;
import org.apromore.dao.model.*;
import org.apromore.service.EventLogService;
import org.apromore.service.impl.EventLogServiceImpl;
import org.apromore.cache.ehcache.CacheRepositoryImpl;
import org.springframework.aop.Advisor;
import org.springframework.aop.framework.Advised;
import org.springframework.aop.support.AopUtils;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import net.sf.ehcache.CacheManager;

final class PublicServiceCorpusHarness {
    static Map<String,Object> obj(Object... p){return PublicServiceHarness.obj(p);}
    static Map<String,Object> exception(Throwable e){
        List<Map<String,Object>> chain=new ArrayList<>();
        Set<Throwable> seen=Collections.newSetFromMap(new IdentityHashMap<>());
        while(e!=null&&seen.add(e)){chain.add(obj("class",e.getClass().getName(),"message",e.getMessage()));e=e.getCause();}
        return obj("chain",chain,"root",chain.get(chain.size()-1));
    }
    static class IntentionalRollback extends RuntimeException {}
    static class CheckedBridge extends RuntimeException {CheckedBridge(Exception e){super(e);}}
    static Map<String,Integer> seed(AnnotationConfigApplicationContext c){
        return new TransactionTemplate(c.getBean(PlatformTransactionManager.class)).execute(status->{
            GroupRepository gr=c.getBean(GroupRepository.class);
            Map<String,Group> groups=new LinkedHashMap<>();
            for(String name:new String[]{"s18-alice","s18-bob","s18-public","s18-team"}){
                Group g=new Group();g.setName(name);g.setRowGuid(name+"-group");
                g.setType(name.equals("s18-public")?Group.Type.PUBLIC:name.equals("s18-team")?Group.Type.GROUP:Group.Type.USER);
                gr.saveAndFlush(g);groups.put(name,g);
            }
            UserRepository ur=c.getBean(UserRepository.class);Map<String,User> users=new HashMap<>();
            for(String name:new String[]{"s18-alice","s18-bob"}){
                User user=new User();user.setUsername(name);user.setRowGuid(name+"-user");user.setMembership(null);
                user.setGroup(groups.get(name));user.getGroups().add(groups.get(name));user.getGroups().add(groups.get("s18-public"));
                ur.saveAndFlush(user);users.put(name,user);
            }
            Map<String,Integer> ids=new LinkedHashMap<>();
            for(String name:new String[]{"owned","foreign"}){
                Folder f=new Folder();f.setName("s18-"+name);f.setCreatedBy(users.get(name.equals("owned")?"s18-alice":"s18-bob"));
                c.getBean(FolderRepository.class).saveAndFlush(f);ids.put(name,f.getId());
                Group owner=groups.get(name.equals("owned")?"s18-alice":"s18-bob");
                c.getBean(GroupFolderRepository.class).saveAndFlush(new GroupFolder(owner,f,true,true,true));
                c.getBean(GroupFolderRepository.class).saveAndFlush(new GroupFolder(groups.get(name.equals("owned")?"s18-team":"s18-alice"),f,true,false,false));
            }
            return ids;
        });
    }
    static Map<String,Object> snapshot(AnnotationConfigApplicationContext c)throws Exception {
        List<Map<String,Object>> files=new ArrayList<>();Path root=PublicServiceHarness.root;
        try(java.util.stream.Stream<Path> paths=Files.walk(root.resolve("files"))){
            for(Path p:(Iterable<Path>)paths.filter(Files::isRegularFile)::iterator)files.add(obj("relative",root.relativize(p).toString(),"bytes",Files.size(p),"sha256",PublicServiceXesObserver.sha(Files.readAllBytes(p))));
        }
        files.sort(Comparator.comparing(f->(String)f.get("relative")));
        List<Map<String,Object>> cache=new ArrayList<>();
        for(Object key:c.getBean(CacheManager.class).getCache("xlog").getKeys()){
            Object value=c.getBean(CacheRepositoryImpl.class).get(key);
            cache.add(obj("key",key.toString(),"value_class",value==null?null:value.getClass().getName()));
        }
        cache.sort(Comparator.comparing(e->(String)e.get("key")));
        return obj("database",obj("logs",c.getBean(LogRepository.class).count(),"storage",c.getBean(StorageRepository.class).count(),"group_logs",c.getBean(GroupLogRepository.class).count()),"files",files,"cache",cache);
    }
    static org.apromore.dao.model.Log invoke(EventLogService service,Map<String,Object> spec,Map<String,Integer> folders,Path fixture)throws Exception {
        String folder=(String)spec.get("folder");
        try(InputStream input=Files.newInputStream(fixture)){
            return service.importLog((String)spec.get("username"),folder==null?null:folders.get(folder),(String)spec.get("log_name"),input,
                (String)spec.get("extension"),(String)spec.get("domain"),(String)spec.get("created"),(Boolean)spec.get("public_model"),(Boolean)spec.get("perspective"));
        }
    }
    public static void main(String[] args)throws Exception {
        if(args.length!=4)throw new IllegalArgumentException("new-state manifest.json case-id output.json");
        Path state=Path.of(args[0]).toAbsolutePath().normalize(),manifest=Path.of(args[1]).toAbsolutePath(),out=Path.of(args[3]);
        if(Files.exists(state)||Files.exists(out))throw new IllegalArgumentException("fresh state and observation required");
        Map<String,Object> m=new ObjectMapper().readValue(Files.readAllBytes(manifest),Map.class),spec=null;
        for(Object row:(List<?>)m.get("corpus"))if(args[2].equals(((Map<?,?>)row).get("id")))spec=(Map<String,Object>)row;
        if(spec==null)throw new IllegalArgumentException("named frozen case required");
        final Map<String,Object> selected=spec;
        Path fixture=manifest.getParent().resolve((String)spec.get("file")).normalize();
        String hash=PublicServiceXesObserver.sha(Files.readAllBytes(fixture));
        if(!hash.equalsIgnoreCase((String)spec.get("sha256")))throw new IllegalArgumentException("frozen fixture hash");
        PublicServiceHarness.root=state;PublicServiceHarness.reopening=false;PublicServiceHarness.entries.clear();
        for(String part:new String[]{"db","cache","files"})Files.createDirectories(state.resolve(part));
        Map<String,Object> result=obj("schema_version",1,"id",args[2],"input_sha256",hash,
            "corpus_sha256",PublicServiceXesObserver.sha(Files.readAllBytes(manifest)),"parameters",spec,
            "service_identity",PublicServiceHarness.identity(EventLogServiceImpl.class),
            "scope","Actual unchanged public importLog username/perspective=false, real reachable dependencies; selective wiring/H2, no Portal/MySQL/perspective=true claim");
        Integer id=null;
        try(AnnotationConfigApplicationContext c=PublicServiceHarness.open()){
            Map<String,Integer> folders=seed(c);result.put("seed_folder_ids",folders);
            EventLogService service=c.getBean(EventLogService.class);
            List<String> advisors=new ArrayList<>();for(Advisor a:((Advised)service).getAdvisors())advisors.add(a.getAdvice().getClass().getName());
            if(!AopUtils.isAopProxy(service)||advisors.stream().noneMatch(a->a.equals("org.springframework.transaction.interceptor.TransactionInterceptor"))||advisors.size()<2)throw new IllegalStateException("actual transaction and observation advisors required");
            result.put("proxy",obj("is_aop_proxy",true,"target_class",AopUtils.getTargetClass(service).getName(),"advice",advisors));
            if(args[2].equals("duplicate-owned-name")){
                org.apromore.dao.model.Log baseline=invoke(service,spec,folders,fixture);
                result.put("baseline_log",PublicServiceHarness.saved(c,baseline.getId()));
            }
            PublicServiceHarness.entries.clear();result.put("before",snapshot(c));
            if(args[2].equals("outer-rollback")){
                final Integer[] transientId={null};
                try{
                    new TransactionTemplate(c.getBean(PlatformTransactionManager.class)).execute(status->{
                        try{
                            transientId[0]=invoke(service,selected,folders,fixture).getId();
                            throw new IntentionalRollback();
                        }catch(IntentionalRollback intentional){throw intentional;}catch(Exception e){throw new CheckedBridge(e);}
                    });
                    throw new IllegalStateException("intentional outer rollback did not throw");
                }catch(IntentionalRollback intentional){result.put("outcome","outer_rollback");result.put("transient_returned_log_id",transientId[0]);}
            }else{
                try{id=invoke(service,spec,folders,fixture).getId();result.put("outcome","success");}
                catch(Exception e){result.put("outcome","exception");result.put("exception",exception(e));}
            }
            result.put("after",snapshot(c));
            if(id!=null)result.put("first_readback",PublicServiceHarness.saved(c,id));
            List<Map<String,Object>> entries=new ArrayList<>(PublicServiceHarness.entries);
            if(entries.isEmpty()||entries.stream().anyMatch(e->!Boolean.TRUE.equals(e.get("actual_transaction_active"))||!Boolean.TRUE.equals(e.get("synchronization_active"))))throw new IllegalStateException("actual inside-business transaction evidence required");
            result.put("transaction_entries",entries);
        }
        PublicServiceHarness.reopening=true;
        try(AnnotationConfigApplicationContext c=PublicServiceHarness.open()){
            result.put("reopened_before_read",snapshot(c));
            if(id!=null)result.put("reopened_readback",PublicServiceHarness.saved(c,id));
            result.put("reopened_after_read",snapshot(c));
        }
        result.put("status","ACTUAL_PUBLIC_CASE_OBSERVED");PublicServiceHarness.write(out,result);
    }
}
