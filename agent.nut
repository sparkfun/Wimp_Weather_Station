// This agent gathers data from the device and pushes to Wunderground
// Talks to wunderground rapid fire server (updates of up to once every 10 sec)
// by: Nathan Seidle
//     SparkFun Electronics
// date: October 4, 2013
// license: BeerWare
//          Please use, reuse, and modify this code as you need.
//          We hope it saves you some time, or helps you learn something!
//          If you find it handy, and we meet some day, you can buy me a beer or iced tea in return.

// Example incoming serial string from device: 
// $,winddir=270,windspeedmph=0.0,windgustmph=0.0,windgustdir=0,windspdmph_avg2m=0.0,winddir_avg2m=12,windgustmph_10m=0.0,windgustdir_10m=0,humidity=998.0,tempf=-1766.2,rainin=0.00,dailyrainin=0.00,pressure=-999.00,batt_lvl=16.11,light_lvl=3.32,#

local STATION_ID = "KCOBOULD95";
local STATION_PW = "password"; //Note that you must only use alphanumerics in your password. Http post won't work otherwise.

local sparkfun_publicKey = "dZ4EVmE8yGCRGx5XRX1W";
local sparkfun_privateKey = "privatekey";

local LOCAL_ALTITUDE_METERS = 1638; //Accurate for the roof on my house

local midnightReset = false; //Keeps track of a once per day cumulative rain reset

local local_hour_offset = 7; //Mountain time is 7 hours off GMT

const MAX_PROGRAM_SIZE = 0x20000;
const ARDUINO_BLOB_SIZE = 128;
program <- null;

//------------------------------------------------------------------------------------------------------------------------------
html <- @"<HTML>
<BODY>

<form method='POST' enctype='multipart/form-data'>
Program the ATmega328 via the Imp.<br/><br/>
Step 1: Select an Intel HEX file to upload: <input type=file name=hexfile><br/>
Step 2: <input type=submit value=Press> to upload the file.<br/>
Step 3: Check out your Arduino<br/>
</form>

</BODY>
</HTML>
";

//------------------------------------------------------------------------------------------------------------------------------
// Parses a HTTP POST in multipart/form-data format
function parse_hexpost(req, res) {
    local boundary = req.headers["content-type"].slice(30);
    local bindex = req.body.find(boundary);
    local hstart = bindex + boundary.len();
    local bstart = req.body.find("\r\n\r\n", hstart) + 4;
    local fstart = req.body.find("\r\n\r\n--" + boundary + "--", bstart);
    return req.body.slice(bstart, fstart);
}


//------------------------------------------------------------------------------------------------------------------------------
// Parses a hex string and turns it into an integer
function hextoint(str) {
    local hex = 0x0000;
    foreach (ch in str) {
        local nibble;
        if (ch >= '0' && ch <= '9') {
            nibble = (ch - '0');
        } else {
            nibble = (ch - 'A' + 10);
        }
        hex = (hex << 4) + nibble;
    }
    return hex;
}


//------------------------------------------------------------------------------------------------------------------------------
// Breaks the program into chunks and sends it to the device
function send_program() {
    if (program != null && program.len() > 0) {
        local addr = 0;
        local pline = {};
        local max_addr = program.len();
        
        device.send("burn", {first=true});
        while (addr < max_addr) {
            program.seek(addr);
            pline.data <- program.readblob(ARDUINO_BLOB_SIZE);
            pline.addr <- addr / 2; // Address space is 16-bit
            device.send("burn", pline)
            addr += pline.data.len();
        }
        device.send("burn", {last=true});
    }
}        

//------------------------------------------------------------------------------------------------------------------------------
// Parse the hex into an array of blobs
function parse_hexfile(hex) {
    
    try {
        // Look at this doc to work out what we need and don't. Max is about 122kb.
        // https://bluegiga.zendesk.com/entries/42713448--REFERENCE-Updating-BLE11x-firmware-using-UART-DFU
        server.log("Parsing hex file");
        
        // Create and blank the program blob
        program = blob(0x20000); // 128k maximum
        for (local i = 0; i < program.len(); i++) program.writen(0x00, 'b');
        program.seek(0);
        
        local maxaddress = 0, from = 0, to = 0, line = "", offset = 0x00000000;
        do {
            if (to < 0 || to == null || to >= hex.len()) break;
            from = hex.find(":", to);
            
            if (from < 0 || from == null || from+1 >= hex.len()) break;
            to = hex.find(":", from+1);
            
            if (to < 0 || to == null || from >= to || to >= hex.len()) break;
            line = hex.slice(from+1, to);
            // server.log(format("[%d,%d] => %s", from, to, line));
            
            if (line.len() > 10) {
                local len = hextoint(line.slice(0, 2));
                local addr = hextoint(line.slice(2, 6));
                local type = hextoint(line.slice(6, 8));

                // Ignore all record types except 00, which is a data record. 
                // Look out for 02 records which set the high order byte of the address space
                if (type == 0) {
                    // Normal data record
                } else if (type == 4 && len == 2 && addr == 0 && line.len() > 12) {
                    // Set the offset
                    offset = hextoint(line.slice(8, 12)) << 16;
                    if (offset != 0) {
                        server.log(format("Set offset to 0x%08X", offset));
                    }
                    continue;
                } else {
                    server.log("Skipped: " + line)
                    continue;
                }

                // Read the data from 8 to the end (less the last checksum byte)
                program.seek(offset + addr)
                for (local i = 8; i < 8+(len*2); i+=2) {
                    local datum = hextoint(line.slice(i, i+2));
                    program.writen(datum, 'b')
                }
                
                // Checking the checksum would be a good idea but skipped for now
                local checksum = hextoint(line.slice(-2));
                
                /// Shift the end point forward
                if (program.tell() > maxaddress) maxaddress = program.tell();
                
            }
        } while (from != null && to != null && from < to);

        // Crop, save and send the program 
        server.log(format("Max address: 0x%08x", maxaddress));
        program.resize(maxaddress);
        send_program();
        server.log("Free RAM: " + (imp.getmemoryfree()/1024) + " kb")
        return true;
        
    } catch (e) {
        server.log(e)
        return false;
    }
    
}


//------------------------------------------------------------------------------------------------------------------------------
// Handle the agent requests
http.onrequest(function (req, res) {
    // return res.send(400, "Bad request");
    // server.log(req.method + " to " + req.path)
    if (req.method == "GET") {
        res.send(200, html);
    } else if (req.method == "POST") {

        if ("content-type" in req.headers) {
            if (req.headers["content-type"].len() >= 19
             && req.headers["content-type"].slice(0, 19) == "multipart/form-data") {
                local hex = parse_hexpost(req, res);
                if (hex == "") {
                    res.header("Location", http.agenturl());
                    res.send(302, "HEX file uploaded");
                } else {
                    device.on("done", function(ready) {
                        res.header("Location", http.agenturl());
                        res.send(302, "HEX file uploaded");                        
                        server.log("Programming completed")
                    })
                    server.log("Programming started")
                    parse_hexfile(hex);
                }
            } else if (req.headers["content-type"] == "application/json") {
                local json = null;
                try {
                    json = http.jsondecode(req.body);
                } catch (e) {
                    server.log("JSON decoding failed for: " + req.body);
                    return res.send(400, "Invalid JSON data");
                }
                local log = "";
                foreach (k,v in json) {
                    if (typeof v == "array" || typeof v == "table") {
                        foreach (k1,v1 in v) {
                            log += format("%s[%s] => %s, ", k, k1, v1.tostring());
                        }
                    } else {
                        log += format("%s => %s, ", k, v.tostring());
                    }
                }
                server.log(log)
                return res.send(200, "OK");
            } else {
                return res.send(400, "Bad request");
            }
        } else {
            return res.send(400, "Bad request");
        }
    }
})


//------------------------------------------------------------------------------------------------------------------------------
// Handle the device coming online
device.on("ready", function(ready) {
    if (ready) send_program();
});

//------------------------------------------------------------------------------------------------------------------------------


// When we hear something from the device, split it apart and post it
device.on("postToInternet", function(dataString) {
    
    //server.log("Incoming: " + dataString);
    
    //Break the incoming string into pieces by comma
    a <- mysplit(dataString,',');

    if(a[0] != "$" || a[16] != "#")
    {
        server.log(format("Error: incorrect frame received (%s, %s)", a[0], a[16]));
        server.log(format("Received: %s)", dataString));
        return(0);
    }
    
    //Pull the various bits from the blob
    
    //a[0] is $
    local winddir = a[1];
    local windspeedmph = a[2];
    local windgustmph = a[3];
    local windgustdir = a[4];
    local windspdmph_avg2m = a[5];
    local winddir_avg2m = a[6];
    local windgustmph_10m = a[7];
    local windgustdir_10m = a[8];
    local humidity = a[9];
    local tempf = a[10];
    local rainin = a[11];
    local dailyrainin = a[12];
    local pressure = a[13].tofloat();
    local batt_lvl = a[14];
    local light_lvl = a[15];
    //a[16] is #
    
    server.log(tempf);
    
    //Correct for the actual orientation of the weather station
    //For my station the north indicator is pointing due west
    winddir = windCorrect(winddir);
    windgustdir = windCorrect(windgustdir);
    winddir_avg2m = windCorrect(winddir_avg2m);
    windgustdir_10m = windCorrect(windgustdir_10m);

    //Correct for negative temperatures. This is fixed in the latest libraries: https://learn.sparkfun.com/tutorials/mpl3115a2-pressure-sensor-hookup-guide
    currentTemp <- mysplit(tempf, '=');
    local badTempf = currentTemp[1].tointeger();
    if(badTempf > 200)
    {
        local tempc = (badTempf - 32) * 5/9; //Convert F to C
        tempc = (tempc<<24)>>24; //Force this 8 bit value into 32 bit variable
        tempc = ~(tempc) + 1; //Take 2s compliment
        tempc *= -1; //Assign negative sign
        tempf = tempc * 9/5 + 32; //Convert back to F
        tempf = "tempf=" + tempf; //put a string on it
    }

    //Correct for humidity out of bounds
    currentHumidity <- mysplit(humidity, '=');
    if(currentHumidity[1].tointeger() > 99) humidity = "humidity=99";
    if(currentHumidity[1].tointeger() < 0) humidity = "humidity=0";

    //Turn Pascal pressure into baromin (Inches Mercury at Altimeter Setting)
    local baromin = "baromin=" + convertToInHg(pressure);
    
    //Calculate a dew point
    currentHumidity <- mysplit(humidity, '=');
    currentTempF <- mysplit(tempf, '=');
    local dewptf = "dewptf=" + calcDewPoint(currentHumidity[1].tointeger(), currentTempF[1].tointeger());

    //Now we form the large string to pass to wunderground
    local strMainSite = "http://rtupdate.wunderground.com/weatherstation/updateweatherstation.php";

    local strID = "ID=" + STATION_ID;
    local strPW = "PASSWORD=" + STATION_PW;

    //Form the current date/time
    //Note: .month is 0 to 11!
    local currentTime = date(time(), 'u');
    local strCT = "dateutc=";
    strCT += currentTime.year + "-" + format("%02d", currentTime.month + 1) + "-" + format("%02d", currentTime.day);
    strCT += "+" + format("%02d", currentTime.hour) + "%3A" + format("%02d", currentTime.min) + "%3A" + format("%02d", currentTime.sec);
    //Not sure if wunderground expects the + or a %2B. We shall see.
    //server.log(strCT);

    local bigString = strMainSite;
    bigString += "?" + strID;
    bigString += "&" + strPW;
    bigString += "&" + strCT;
    bigString += "&" + winddir;
    bigString += "&" + windspeedmph;
    bigString += "&" + windgustmph;
    bigString += "&" + windgustdir;
    bigString += "&" + windspdmph_avg2m;
    bigString += "&" + winddir_avg2m;
    bigString += "&" + windgustmph_10m;
    bigString += "&" + windgustdir_10m;
    bigString += "&" + humidity;
    bigString += "&" + tempf;
    bigString += "&" + rainin;
    bigString += "&" + dailyrainin;
    bigString += "&" + baromin;
    bigString += "&" + dewptf;
    //bigString += "&" + weather;
    //bigString += "&" + clouds;
    bigString += "&" + "softwaretype=SparkFunWeatherImp"; //Cause we can
    bigString += "&" + "realtime=1"; //You better believe it!
    bigString += "&" + "rtfreq=10"; //Set rapid fire freq to once every 10 seconds
    bigString += "&" + "action=updateraw";

    //server.log("string to send: " + bigString);
    
    //Push to Wunderground
    local request = http.post(bigString, {}, "");
    local response = request.sendsync();
    server.log("Wunderground response = " + response.body);
    server.log(batt_lvl + " " + light_lvl);

    //Get the local time that this measurement was taken
    local localMeasurementTime = "measurementtime=" + calcLocalTime();

    //Now post to data.sparkfun.com
    //Here is a list of datums: measurementTime, winddir, windspeedmph, windgustmph, windgustdir, windspdmph_avg2m, winddir_avg2m, windgustmph_10m, windgustdir_10m, humidity, tempf, rainin, dailyrainin, baromin, dewptf, batt_lvl, light_lvl

    //Now we form the large string to pass to sparkfun
    local strSparkFun = "http://data.sparkfun.com/input/";
    local privateKey = "private_key=" + sparkfun_privateKey;

    bigString = strSparkFun;
    bigString += sparkfun_publicKey;
    bigString += "?" + privateKey;
    bigString += "&" + localMeasurementTime;
    bigString += "&" + winddir;
    bigString += "&" + windspeedmph;
    bigString += "&" + windgustmph;
    bigString += "&" + windgustdir;
    bigString += "&" + windspdmph_avg2m;
    bigString += "&" + winddir_avg2m;
    bigString += "&" + windgustmph_10m;
    bigString += "&" + windgustdir_10m;
    bigString += "&" + humidity;
    bigString += "&" + tempf;
    bigString += "&" + rainin;
    bigString += "&" + dailyrainin;
    bigString += "&" + baromin;
    bigString += "&" + dewptf;
    bigString += "&" + batt_lvl;
    bigString += "&" + light_lvl;
    
    //Push to SparkFun
    local request = http.get(bigString);
    local response = request.sendsync();
    server.log("SparkFun response = " + response.body);

    //Check to see if we need to send a midnight reset
    checkMidnight(1);

    server.log("Update complete!");
}); 

//Given a string, break out the direction, correct by some value
//Return a string
function windCorrect(direction) {
    temp <- mysplit(direction, '=');

    //My station's North arrow is pointing due west
    //So correct by 90 degrees
    local dir = temp[1].tointeger() - 90; 
    if(dir < 0) dir += 360;
    return(temp[0] + "=" + dir);
}

//With relative humidity and temp, calculate a dew point
//From: http://ag.arizona.edu/azmet/dewpoint.html
function calcDewPoint(relativeHumidity, tempF) {
    local tempC = (tempF - 32) * 5 / 9.0;

    local L = math.log(relativeHumidity / 100.0);
    local M = 17.27 * tempC;
    local N = 237.3 + tempC;
    local B = (L + (M / N)) / 17.27;
    local dewPoint = (237.3 * B) / (1.0 - B);
    
    //Result is in C
    //Convert back to F
    dewPoint = dewPoint * 9 / 5.0 + 32;

    //server.log("rh=" + relativeHumidity + " tempF=" + tempF + " tempC=" + tempC);
    //server.log("DewPoint = " + dewPoint);
    return(dewPoint);
}

function checkMidnight(ignore) {
    //Check to see if it's midnight. If it is, send @ to Arduino to reset time based variables

    //Get the local time that this measurement was taken
    local localTime = calcLocalTime(); 
    
    //server.log("Local hour = " + format("%c", localTime[0]) + format("%c", localTime[1]));

    if(localTime[0].tochar() == "0" && localTime[1].tochar() == "4")
    {
        if(midnightReset == false)
        {
            server.log("Sending midnight reset");
            midnightReset = true; //We should only reset once
            device.send("sendMidnightReset", 1);
        }
    }
    else {
        midnightReset = false; //Reset our state
    }
}
    
//Recording to a google doc is a bit tricky. Many people have found ways of posting
//to a google form to get data into a spreadsheet. This requires a https connection
//so we use pushingbox to handle the secure connection.
//See http://productforums.google.com/forum/#!topic/docs/f4hJKF1OQOw for more info
//To push two items I had to use a GET instead of a post
function recordLevels(batt, light) {
    
    //Smash it all together
    local stringToSend = "http://api.pushingbox.com/pushingbox?devid=vB0A3446EBB4828F";
    stringToSend = stringToSend + "&" + batt; 
    stringToSend = stringToSend + "&" + light;
    //server.log("string to send: " + stringToSend); //Debugging
    
    //Push to internet
    local request = http.post(stringToSend, {}, "");
    local response = request.sendsync();
    //server.log("Google response=" + response.body);
    
    server.log("Post to spreadsheet complete.")
}

//Given pressure in pascals, convert the pressure to Altimeter Setting, inches mercury
function convertToInHg(pressure_Pa)
{
    local pressure_mb = pressure_Pa / 100; //pressure is now in millibars, 1 pascal = 0.01 millibars
    
    local part1 = pressure_mb - 0.3; //Part 1 of formula
    local part2 = 8.42288 / 100000.0;
    local part3 = math.pow((pressure_mb - 0.3), 0.190284);
    local part4 = LOCAL_ALTITUDE_METERS / part3;
    local part5 = (1.0 + (part2 * part4));
    local part6 = math.pow(part5, (1.0/0.190284));
    local altimeter_setting_pressure_mb = part1 * part6; //Output is now in adjusted millibars
    local baromin = altimeter_setting_pressure_mb * 0.02953;
    //server.log(format("%s", baromin));
    return(baromin);
}

//From Hugo: http://forums.electricimp.com/discussion/915/processing-nmea-0183-gps-strings/p1
//You rock! Thanks Hugo!
function mysplit(a, b) {
  local ret = [];
  local field = "";
  foreach(c in a) {
      if (c == b) {
          // found separator, push field
          ret.push(field);
          field="";
      } else {
          field += c.tochar(); // append to field
      }
   }
   // Push the last field
   ret.push(field);
   return ret;
}

//Given UTC time and a local offset and a date, calculate the local time
//Includes a daylight savings time calc for the US
function calcLocalTime()
{
    //Get the time that this measurement was taken
    local currentTime = date(time(), 'u');
    local hour = currentTime.hour; //Most of the work will be on the current hour

    //Since 2007 DST starts on the second Sunday in March and ends the first Sunday of November
    //Let's just assume it's going to be this way for awhile (silly US government!)
    //Example from: http://stackoverflow.com/questions/5590429/calculating-daylight-savings-time-from-only-date
    
    //The Imp .month returns 0-11. DoW expects 1-12 so we add one.
    local month = currentTime.month + 1;
    
    local DoW = day_of_week(currentTime.year, month, currentTime.day); //Get the day of the week. 0 = Sunday, 6 = Saturday
    local previousSunday = currentTime.day - DoW;

    local dst = false; //Assume we're not in DST
    if(month > 3 && month < 11) dst = true; //DST is happening!

    //In March, we are DST if our previous Sunday was on or after the 8th.
    if (month == 3)
    {
        if(previousSunday >= 8) dst = true; 
    } 
    //In November we must be before the first Sunday to be dst.
    //That means the previous Sunday must be before the 1st.
    if(month == 11)
    {
        if(previousSunday <= 0) dst = true;
    }

    if(dst == true)
    {
        hour++; //If we're in DST add an extra hour
    }

    //Convert UTC hours to local current time using local_hour
    if(hour < local_hour_offset)
        hour += 24; //Add 24 hours before subtracting local offset
    hour -= local_hour_offset;
    
    local AMPM = "AM";
    if(hour > 12)
    {
        hour -= 12; //Get rid of military time
        AMPM = "PM";
    }
    if(hour == 0) hour = 12; //Midnight edge case

    currentTime = format("%02d", hour) + "%3A" + format("%02d", currentTime.min) + "%3A" + format("%02d", currentTime.sec) + "%20" + AMPM;
    //server.log("Local time: " + currentTime);
    return(currentTime);
}

//Given the current year/month/day
//Returns 0 (Sunday) through 6 (Saturday) for the day of the week
//Assumes we are operating in the 2000-2099 century
//From: http://en.wikipedia.org/wiki/Calculating_the_day_of_the_week
function day_of_week(year, month, day)
{

  //offset = centuries table + year digits + year fractional + month lookup + date
  local centuries_table = 6; //We assume this code will only be used from year 2000 to year 2099
  local year_digits;
  local year_fractional;
  local month_lookup;
  local offset;

  //Example Feb 9th, 2011

  //First boil down year, example year = 2011
  year_digits = year % 100; //year_digits = 11
  year_fractional = year_digits / 4; //year_fractional = 2

  switch(month) {
  case 1: 
    month_lookup = 0; //January = 0
    break; 
  case 2: 
    month_lookup = 3; //February = 3
    break; 
  case 3: 
    month_lookup = 3; //March = 3
    break; 
  case 4: 
    month_lookup = 6; //April = 6
    break; 
  case 5: 
    month_lookup = 1; //May = 1
    break; 
  case 6: 
    month_lookup = 4; //June = 4
    break; 
  case 7: 
    month_lookup = 6; //July = 6
    break; 
  case 8: 
    month_lookup = 2; //August = 2
    break; 
  case 9: 
    month_lookup = 5; //September = 5
    break; 
  case 10: 
    month_lookup = 0; //October = 0
    break; 
  case 11: 
    month_lookup = 3; //November = 3
    break; 
  case 12: 
    month_lookup = 5; //December = 5
    break; 
  default: 
    month_lookup = 0; //Error!
    return(-1);
  }

  offset = centuries_table + year_digits + year_fractional + month_lookup + day;
  //offset = 6 + 11 + 2 + 3 + 9 = 31
  offset %= 7; // 31 % 7 = 3 Wednesday!

  return(offset); //Day of week, 0 to 6

  //Example: May 11th, 2012
  //6 + 12 + 3 + 1 + 11 = 33
  //5 = Friday! It works!

   //Devised by Tomohiko Sakamoto in 1993, it is accurate for any Gregorian date:
   /*t <- [ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
   if(month < 3) year--;
   //year = month < 3;
 return (year + year/4 - year/100 + year/400 + t[month-1] + day) % 7;
   //return 4;
   */
}
