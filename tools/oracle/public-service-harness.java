// Own selective integration configuration/observer; upstream classes are unchanged.
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import javax.persistence.EntityManager;
import javax.persistence.EntityManagerFactory;
import javax.sql.DataSource;
import org.aopalliance.intercept.MethodInterceptor;
import org.apromore.dao.*;
import org.apromore.dao.model.*;
import org.apromore.service.*;
import org.apromore.service.impl.*;
import org.apromore.commons.config.ConfigBean;
import org.apromore.storage.factory.*;
import org.apromore.storage.StorageClient;
import org.apromore.cache.ehcache.CacheRepositoryImpl;
import org.apromore.apmlog.impl.APMLogServiceImpl;
import org.deckfour.xes.model.XLog;
import org.springframework.aop.Advisor;
import org.springframework.aop.framework.Advised;
import org.springframework.aop.support.AopUtils;
import org.springframework.aop.support.DefaultPointcutAdvisor;
import org.springframework.aop.support.StaticMethodMatcherPointcut;
import org.springframework.context.support.PropertySourcesPlaceholderConfigurer;
import org.springframework.context.annotation.*;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.*;
import org.springframework.transaction.annotation.*;
import org.springframework.transaction.support.*;
import org.springframework.cache.ehcache.EhCacheCacheManager;
import net.sf.ehcache.CacheManager;
import net.sf.ehcache.config.CacheConfiguration;
import net.sf.ehcache.config.DiskStoreConfiguration;

final class PublicServiceHarness {
    static Path root;
    static boolean reopening;
    static final List<Map<String,Object>> entries=new ArrayList<>();
    static Map<String,Object> obj(Object... pairs){return PublicServiceXesObserver.object(pairs);}
    @Configuration
    @EnableTransactionManagement(order=0)
    @EnableJpaRepositories(basePackages="org.apromore.dao",repositoryImplementationPostfix="CustomImpl",
      includeFilters=@ComponentScan.Filter(type=FilterType.ASSIGNABLE_TYPE,classes={
        UserRepository.class,SearchHistoryRepository.class,LogRepository.class,GroupRepository.class,
        FolderRepository.class,GroupFolderRepository.class,GroupLogRepository.class,StorageRepository.class,
        CustomCalendarRepository.class,GroupUsermetadataRepository.class,UsermetadataRepository.class,
        ProcessRepository.class,GroupProcessRepository.class}))
    static class Wiring {
        @Bean static PropertySourcesPlaceholderConfigurer properties(){
            PropertySourcesPlaceholderConfigurer p=new PropertySourcesPlaceholderConfigurer();
            Properties values=new Properties();values.setProperty("storage.logPrefix","s18");p.setProperties(values);return p;
        }
        @Bean DataSource dataSource(){return new DriverManagerDataSource("jdbc:h2:file:"+root.resolve("db/public").toString().replace('\\','/')+";DB_CLOSE_ON_EXIT=FALSE","sa","");}
        @Bean LocalContainerEntityManagerFactoryBean entityManagerFactory(DataSource dataSource){
            LocalContainerEntityManagerFactoryBean f=new LocalContainerEntityManagerFactoryBean();
            f.setDataSource(dataSource);f.setPackagesToScan("org.apromore.dao.model");
            f.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
            Properties p=new Properties();p.setProperty("hibernate.dialect","org.hibernate.dialect.H2Dialect");
            p.setProperty("hibernate.hbm2ddl.auto",reopening?"validate":"update");
            p.setProperty("hibernate.show_sql","false");p.setProperty("hibernate.format_sql","false");
            f.setJpaProperties(p);return f;
        }
        @Bean PlatformTransactionManager transactionManager(EntityManagerFactory f){return new JpaTransactionManager(f);}
        @Bean JdbcTemplate jdbcTemplate(DataSource ds){return new JdbcTemplate(ds);}
        @Bean(name="config") ConfigBean config(){
            ConfigBean c=new ConfigBean();c.getStorage().setPath("FILE::"+root.resolve("files"));
            c.getLogs().setDir(root.resolve("files").toString());c.getCache().setNumOfEvent("1000");c.getCache().setNumOfTrace("1000");return c;
        }
        @Bean StorageManagementFactory<StorageClient> storageFactory(){return new StorageManagementFactoryImpl<>();}
        @Bean(destroyMethod="shutdown") CacheManager ehcache(){
            net.sf.ehcache.config.Configuration c=new net.sf.ehcache.config.Configuration();
            c.setName("s18-public-"+UUID.randomUUID());
            c.addDiskStore(new DiskStoreConfiguration().path(root.resolve("cache").toString()));
            c.addCache(new CacheConfiguration("xlog",1000).eternal(true).overflowToDisk(false).diskPersistent(false));
            return new CacheManager(c);
        }
        @Bean EhCacheCacheManager ehCacheCacheManager(CacheManager manager){return new EhCacheCacheManager(manager);}
        @Bean CacheRepositoryImpl cacheRepo(EhCacheCacheManager manager){CacheRepositoryImpl r=new CacheRepositoryImpl();r.setEhCacheCacheManager(manager);r.setCacheName("xlog");return r;}
        @Bean APMLogServiceImpl apmLogService(){return new APMLogServiceImpl();}
        @Bean TemporaryCacheService tempCacheService(){return new TemporaryCacheService();}
        @Bean UserService userService(UserRepository r,SearchHistoryRepository s){return new UserServiceImpl(r,s);}
        @Bean AuthorizationService authorizationService(GroupUsermetadataRepository gu,UsermetadataRepository u,
          LogRepository l,ProcessRepository p,FolderRepository f,GroupRepository g,GroupLogRepository gl,
          GroupProcessRepository gp,GroupFolderRepository gf,UserService users){
            // FolderService is outside the selected getFolderAccessTypeByUser method.
            return new AuthorizationServiceImpl(gu,u,l,null,p,f,g,gl,gp,gf,users);
        }
        @Bean EventLogService eventLogService(LogRepository logs,GroupRepository groups,GroupLogRepository rights,
          FolderRepository folders,UserService users,ConfigBean config,TemporaryCacheService cache,
          StorageManagementFactory storage,StorageRepository stored,CustomCalendarRepository calendars,
          AuthorizationService authorization){
            // Explicitly unwired unreachable services: metadata, legacy-file-copy, calendars.
            // perspective=true and legacy Storage-null update paths are NOT admitted.
            return new EventLogServiceImpl(logs,groups,rights,folders,users,config,null,cache,storage,null,stored,calendars,null,authorization);
        }
        @Bean @org.springframework.context.annotation.Role(org.springframework.beans.factory.config.BeanDefinition.ROLE_INFRASTRUCTURE)
        static Advisor activeTransactionObserver(){
            StaticMethodMatcherPointcut p=new StaticMethodMatcherPointcut(){
                public boolean matches(java.lang.reflect.Method m,Class<?> c){return EventLogServiceImpl.class.isAssignableFrom(c)&&m.getName().equals("importLog");}
            };
            DefaultPointcutAdvisor a=new DefaultPointcutAdvisor(p,(MethodInterceptor) invocation->{
                entries.add(obj("method",invocation.getMethod().toGenericString(),"actual_transaction_active",TransactionSynchronizationManager.isActualTransactionActive(),
                    "synchronization_active",TransactionSynchronizationManager.isSynchronizationActive(),"transaction_name",TransactionSynchronizationManager.getCurrentTransactionName()));
                return invocation.proceed();
            });a.setOrder(1);return a;
        }
    }
    static Map<String,Object> identity(Class<?> c)throws Exception {
        String resource="/"+c.getName().replace('.','/')+".class";
        try(InputStream in=c.getResourceAsStream(resource)){
            return obj("class",c.getName(),"sha256",PublicServiceXesObserver.sha(in.readAllBytes()),"code_source",c.getProtectionDomain().getCodeSource().getLocation().toString());
        }
    }
    static void write(Path path,Object value)throws Exception{Files.write(path,new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsBytes(value),StandardOpenOption.CREATE_NEW);}
    static AnnotationConfigApplicationContext open(){return new AnnotationConfigApplicationContext(Wiring.class);}
    static Map<String,Object> saved(AnnotationConfigApplicationContext context,Integer id)throws Exception {
        TransactionTemplate tx=new TransactionTemplate(context.getBean(PlatformTransactionManager.class));
        return tx.execute(status->{
            org.apromore.dao.model.Log log=context.getBean(LogRepository.class).findById(id).get();
            List<Map<String,Object>> rights=new ArrayList<>();
            for(GroupLog r:log.getGroupLogs())rights.add(obj("group_id",r.getGroup().getId(),"group_name",r.getGroup().getName(),"group_type",r.getGroup().getType().toString(),"read",r.getAccessRights().isReadOnly(),"write",r.getAccessRights().isWriteOnly(),"owner",r.getAccessRights().isOwnerShip()));
            rights.sort(Comparator.comparing(r->(Integer)r.get("group_id")));
            Storage storage=log.getStorage();
            XLog xlog=context.getBean(TemporaryCacheService.class).getProcessLog(log,null);
            Object apm=context.getBean(CacheRepositoryImpl.class).get(storage.getKey()+"APMLog");
            return obj("id",log.getId(),"name",log.getName(),"domain",log.getDomain(),"created",log.getCreateDate(),"file_path",log.getFilePath(),"user_id",log.getUser().getId(),"folder_id",log.getFolder()==null?null:log.getFolder().getId(),
              "storage",obj("id",storage.getId(),"key",storage.getKey(),"prefix",storage.getPrefix(),"path",storage.getStoragePath()),"rights",rights,
              "reloaded_log",xlog==null?null:PublicServiceXesObserver.log(xlog),
              "reloaded_log_status",xlog==null?"actual_service_returned_null":"available",
              "apm_cache_class",apm==null?null:apm.getClass().getName());
        });
    }
    public static void main(String[] args)throws Exception {
        if(args.length!=3)throw new IllegalArgumentException("new-private-state fixture.xes observation.json");
        root=Path.of(args[0]).toAbsolutePath().normalize();Path fixture=Path.of(args[1]),out=Path.of(args[2]);
        if(Files.exists(root)||Files.exists(out))throw new IllegalArgumentException("fresh paths required");
        for(String directory:new String[]{"db","files","cache"})Files.createDirectories(root.resolve(directory));
        Map<String,Object> result=obj("schema_version",1,"scope","actual unchanged public importLog username perspective=false, H2+Springtransaction+FILE+cache; no Portal/MySQL/fullwiring claim",
            "input_sha256",PublicServiceXesObserver.sha(Files.readAllBytes(fixture)),"service_identity",identity(EventLogServiceImpl.class),
            "unwired_unreachable_services",Arrays.asList("UserMetadataService","legacy EventLogFileService","CalendarService","AuthorizationService.FolderService"));
        Integer importedId;
        try(AnnotationConfigApplicationContext context=open()){
            EventLogService service=context.getBean(EventLogService.class);
            List<String> advisors=new ArrayList<>();for(Advisor a:((Advised)service).getAdvisors())advisors.add(a.getAdvice().getClass().getName());
            result.put("proxy",obj("is_aop_proxy",AopUtils.isAopProxy(service),"target_class",AopUtils.getTargetClass(service).getName(),"advice",advisors));
            TransactionTemplate tx=new TransactionTemplate(context.getBean(PlatformTransactionManager.class));
            tx.execute(s->{
                Group personal=new Group();personal.setName("s18-alice");personal.setRowGuid("s18-alice-group");personal.setType(Group.Type.USER);context.getBean(GroupRepository.class).saveAndFlush(personal);
                Group everyone=new Group();everyone.setName("s18-public");everyone.setRowGuid("s18-public-group");everyone.setType(Group.Type.PUBLIC);context.getBean(GroupRepository.class).saveAndFlush(everyone);
                User user=new User();user.setUsername("s18-alice");user.setRowGuid("s18-alice-user");user.setGroup(personal);user.getGroups().add(personal);user.getGroups().add(everyone);user.setMembership(null);
                context.getBean(UserRepository.class).saveAndFlush(user);return null;
            });
            try(InputStream input=Files.newInputStream(fixture)){
                org.apromore.dao.model.Log imported=service.importLog("s18-alice",null,"Public gate",input,"xes","s18-domain","2026-10-21",false,false);
                importedId=imported.getId();
            }
            result.put("first_readback",saved(context,importedId));
            result.put("transaction_entries",new ArrayList<>(entries));
        }
        reopening=true;
        try(AnnotationConfigApplicationContext context=open()){result.put("reopened_readback",saved(context,importedId));}
        List<Map<String,Object>> files=new ArrayList<>();
        try(java.util.stream.Stream<Path> paths=Files.walk(root.resolve("files"))){
            for(Path file:(Iterable<Path>)paths.filter(Files::isRegularFile)::iterator)files.add(obj("relative",root.relativize(file).toString(),"sha256",PublicServiceXesObserver.sha(Files.readAllBytes(file)),"bytes",Files.size(file)));
        }
        result.put("storage_files",files);result.put("status","ACTUAL_PUBLIC_MINIMAL_GATE_COMPLETED");write(out,result);
    }
}
