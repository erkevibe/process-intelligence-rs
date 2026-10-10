if(!process.env.PLAYWRIGHT_MODULE||!process.env.BROWSER_EXECUTABLE)throw Error('Set bundled paths');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE);const fs=require('fs'),path=require('path');
const base=(process.env.BASE_URL||'http://127.0.0.1:3000').replace(/\/$/,'');const out=path.resolve(process.env.QA_BROWSER_OUTPUT||'.local/qa-browser-optional');fs.mkdirSync(out,{recursive:true});
const results=[],exceptions=[],streams=[];const record=(name,passed,detail)=>results.push({name,passed,detail});
(async()=>{const browser=await chromium.launch({headless:true,executablePath:process.env.BROWSER_EXECUTABLE});const context=await browser.newContext({viewport:{width:1440,height:1100}});const page=await context.newPage();page.on('pageerror',e=>exceptions.push(e.message));page.on('request',r=>{if(/\/jobs\/job-\d+\/events$/.test(new URL(r.url()).pathname))streams.push(r.url());});
const upload=async(name,background)=>{await page.goto(base);await page.locator('#background-mode').setChecked(background);await page.locator('#xes-file').setInputFiles(path.resolve(name));const [response]=await Promise.all([page.waitForNavigation(),page.locator('#upload-form button[type=submit]').click()]);return response;};
const exported=async()=>{const href=await page.locator('a[href$="/export"]').getAttribute('href');return(await context.request.get(new URL(href,base).href)).json();};
try{
 const response=await upload('fixtures/manual.xes',true);record('native jobs accepted202',response.status()===202,{status:response.status()});
 await page.waitForFunction(()=>document.getElementById('job-panel')?.dataset.jobState==='Completed',{},{timeout:20000});await page.waitForFunction(()=>window.piGraphSnapshot?.()?.nodes===3);
 const jobId=await page.locator('#job-panel').getAttribute('data-job-id');record('real job stream GET',streams.some(u=>u.includes(jobId)),streams);
 let e=await exported();record('completed job graph counts',e.analysis.events===10&&(await page.evaluate(()=>window.piGraphSnapshot())).edges===4,null);
 const terminalReplay=await context.request.get(base+'/jobs/'+jobId+'/events');record('terminal SSE reconnect snapshot',terminalReplay.status()===200&&(await terminalReplay.text()).includes('Completed'),{status:terminalReplay.status()});
 await upload('fixtures/invalid-timestamp.xes',true);await page.waitForFunction(()=>document.getElementById('job-panel')?.dataset.jobState==='Failed',{},{timeout:10000});record('job failed visible',true,await page.locator('#job-panel').innerText());
 await upload('.local/qa-generated/events-100000.xes',true);const cancelButton=page.locator('#job-panel button');await cancelButton.click();await page.waitForFunction(()=>document.getElementById('job-panel')?.dataset.jobState==='Cancelled',{},{timeout:20000});
 const cancelledId=await page.locator('#job-panel').getAttribute('data-job-id');const cancelled=await(await context.request.get(base+'/jobs/'+cancelledId)).json();record('actual job cancel never publishes',cancelled.state==='cancelled'&&cancelled.cancel_requested&&cancelled.result_id===null,cancelled);
 await upload('fixtures/semantics.xes',false);await page.waitForFunction(()=>window.piGraphSnapshot?.()?.nodes===3);e=await exported();const original=e.analysis;
 const caseButtons=page.locator('.case-button');const empty=caseButtons.filter({hasText:'0 событий'});await empty.click();await page.waitForFunction(()=>window.piGraphSnapshot?.()?.selected_case_id!==null);
 e=await exported();record('empty case no highlights',e.selected_case.events.length===0&&(await page.evaluate(()=>window.piGraphSnapshot())).highlighted.length===0,await page.locator('#case-details').innerText());
 const two=caseButtons.filter({hasText:'2 событий'});await two.click();await page.waitForFunction(()=>window.piGraphSnapshot?.()?.highlighted.length===2);await page.locator('#graph-zoom-in').click();const before=await page.evaluate(()=>window.piGraphSnapshot());
 await page.locator('#threshold-form input[name=threshold]').evaluate(el=>{el.value='2';el.dispatchEvent(new Event('change',{bubbles:true}));});await page.waitForFunction(()=>window.piGraphSnapshot?.()?.edges===0);
 e=await exported();const after=await page.evaluate(()=>window.piGraphSnapshot());record('case hidden edges samepan counts preserved',after.highlighted.length===1&&after.selected_case_id===before.selected_case_id&&after.zoom===before.zoom&&after.pan.x===before.pan.x&&JSON.stringify(e.analysis)===JSON.stringify(original),{before,after});
 record('case visible details',e.selected_case.events.length===2&&(await page.locator('#case-details').innerText()).includes('скрыты'),null);
 await page.screenshot({path:path.join(out,'optional-case.png'),fullPage:true});
}catch(error){record('optional exception',false,error.stack);await page.screenshot({path:path.join(out,'failure.png'),fullPage:true});}
record('JavaScript exceptions',exceptions.length===0,exceptions);fs.writeFileSync(path.join(out,'report.json'),JSON.stringify({run_id:'sprint-01',time_utc:new Date().toISOString(),results,streams},null,2));console.log(JSON.stringify(results,null,2));await browser.close();})().catch(e=>{console.error(e);process.exitCode=1;});
