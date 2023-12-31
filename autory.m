clear; close all; clc;
rosshutdown;
rosinit('http://localhost:11311')
tftree = rostf;
pause(3);

pp=controllerPurePursuit;
pp.LookaheadDistance=3; % m
pp.DesiredLinearVelocity=3; % m/s
pp.MaxAngularVelocity = 2.0; % rad/s
yaw = [0;0];
gpsSub = rossubscriber('/ublox_gps/fix');
speedSub = rossubscriber('/arduino_speed_out');
utmSpeedSub = rossubscriber('/arduino_speed_out');
imuSub = rossubscriber('/imu');
prevw = 0;

waypoints = [];
% tic;

while true
    redCones = [];
    yellowCones = [];
    blueCones = [];


    % Emergency Stop by red cones for Brake test
    while redConeBrake(redCones) == 1
        [pub, msg] = publish_twist_command(0, w, '/ackermann_steering_controller/cmd_vel');
        send(pub, msg);
    end

    posUtmData = receive(gpsSub);
    veloArdData = receive(speedSub);
    veloUtmData = receive(utmSpeedSub);
    velo = updateVehicleVelo(currentVeloArd,currentVeloUtm);
    imuData = receive(imuSub);


    vehiclePose = updateVehiclePose(posUtmData,imuData);

    if isempty(pp.Waypoints) || norm(worldWaypoints(end,:)-[vehiclePose(1), vehiclePose(2)]) < waypointTreshold  % Considering only x and y for the distance
        disp("Make new waypoints");

        try
            % For watching Cone perception
            hold off;
            scatter(innerConePosition(:,1),innerConePosition(:,2),'blue');
            hold on;
            scatter(outerConePosition(:,1),outerConePosition(:,2),'red');

            [innerConePosition, outerConePosition] = match_array_lengths(innerConePosition, outerConePosition);
            waypoints = generate_waypoints_del(innerConePosition, outerConePosition);

            worldWaypoints = transformWaypointsToOdom(waypoints, vehiclePose);

            pp.Waypoints = worldWaypoints;
        catch
            disp("Fail to make new waypoints");
            continue; % 다음 while문 반복으로 넘어감
        end
    end

    [v, w] = pp(vehiclePose);  % Pass the current vehicle pose to the path planner
    if abs(prevw)>abs(w)
        w = -w;
    end
    prevw = w;
    carL = 1.33;
    w = w*400/pi/1e6*30*carL/v;

    [pub, msg] = publish_twist_command(v, w, '/ackermann_steering_controller/cmd_vel');
    send(pub, msg);

    % 종방향 속도, 횡방향 각속도
    tractive_control = v;
    steering_control = w;

end

% getting velo
function currentVelo = updateVehicleVelo(veloArdData, veloUtmData)

xUtmVelo = veloUtmData.Twist.Twist.Linear.X;
yUtmVelo = veloUtmData.Twist.Twist.Linear.Y;
utmVelo = sqrt(xUtmVelo^2+yUtmVelo^2);

finalVelo = veloArdData * 0.4 + utmVelo * 0.6;

currentVelo = finalVelo;
end


function vehiclePose = updateVehiclePose(currentPosUtm, imu)
% Originally Imu gave values in degree but PP needs values in radian.
raw_yaw=imu.x;
if raw_yaw>=90
    yawD = raw_yaw-90;
elseif raw_yaw>=0
    yawD= raw_yaw - 90;
elseif raw_yaw>=-90
    yawD=  -90+raw_yaw;
else
    yawD= 270+raw_yaw;
end
yawRad = yawD * pi / 180;

vehiclePose=[currentPosUtm.pose.position.x,currentPosUtm.pose.position.y,yawRad];
end

function isStop = redConeBrake(redCones)
isStop = 0;

if size(redCones,1) ~= 0
    redConeCnt = 0;
    % for every red cones detected
    for i=1:1:size(redCones,1)
        % distance between one of red cone is under 5meter
        if redCones(i,0)<5
            redConeCnt = redConeCnt+1;
        end
        % if norm(redCones(i,:)) < 6
        %     redConeCnt = redConeCnt+1;
        % end
    end
    if redConeCnt>2
        isStop = 1;
    end
end
end



% Convert Car based waypoint to World based waypoints
function odomWaypoints = transformWaypointsToOdom(waypoints, vehiclePoseInOdom)
% Initialize transformed waypoints
odomWaypoints = zeros(size(waypoints));

% Extract the vehicle's yaw angle
theta = vehiclePoseInOdom(3);

% Create the 2D rotation matrix
R = [cos(theta), -sin(theta);
    sin(theta), cos(theta)];

% Transform each waypoint
for i = 1:size(waypoints,1)
    % Rotate the waypoint considering the vehicle's yaw
    rotatedPoint = R * waypoints(i,:)';

    % Translate considering the vehicle's position in the odom frame
    odomWaypoints(i,:) = rotatedPoint' + vehiclePoseInOdom(1:2)';
end
end





function [out1, out2] = match_array_lengths(arr1, arr2)
len1 = size(arr1, 1); % Get the number of rows
len2 = size(arr2, 1); % Get the number of rows

if len1 > len2
    out1 = arr1(1:len2, :); % Keep only the first len2 rows
    out2 = arr2;
elseif len2 > len1
    out1 = arr1;
    out2 = arr2(1:len1, :); % Keep only the first len1 rows
else
    out1 = arr1;
    out2 = arr2;
end
end

function waypoints = generate_waypoints_del(innerConePosition, outerConePosition)
[m,nc] = size(innerConePosition); % size of the inner/outer cone positions data
kockle_coords = zeros(2*m,nc); % initiate a P matrix consisting of inner and outer coordinates
kockle_coords(1:2:2*m,:) = innerConePosition;
kockle_coords(2:2:2*m,:) = outerConePosition; % merge the inner and outer coordinates with alternate values
xp = []; % create an empty numeric xp vector to store the planned x coordinates after each iteration
yp = [];


interv=size(innerConePosition,1)*2;
%step 1 : delaunay triangulation
tri=delaunayTriangulation(kockle_coords);
pl=tri.Points;
cl=tri.ConnectivityList;
[mc, nc]=size(pl);

% inner and outer constraints when the interval is even
if rem(interv,2) == 0
    cIn = [2 1;(1:2:mc-3)' (3:2:(mc))'; (mc-1) mc];
    cOut = [(2:2:(mc-2))' (4:2:mc)'];
else
    % inner and outer constraints when the interval is odd
    cIn = [2 1;(1:2:mc-2)' (3:2:(mc))'; (mc-1) mc];
    cOut = [(2:2:(mc-2))' (4:2:mc)'];
end

%step 2 : 외부 삼각형 거
C = [cIn;cOut];
TR=delaunayTriangulation(pl,C);
% TRC=TR.ConnectivityList;
TL=isInterior(TR);
TC =TR.ConnectivityList(TL,:);
[~, pt]=sort(sum(TC,2));
TS=TC(pt,:);
TO=triangulation(TS,pl);

%step 3 : 중간 waypoint 생성
xPo=TO.Points(:,1);
yPo=TO.Points(:,2);
E=edges(TO);
iseven=rem(E,2)==0;
Eeven=E(any(iseven,2),:);
isodd=rem(Eeven,2)~=0;
Eodd=Eeven(any(isodd,2),:);
xmp=((xPo((Eodd(:,1))) + xPo((Eodd(:,2))))/2);
ymp=((yPo((Eodd(:,1))) + yPo((Eodd(:,2))))/2);
Pmp=[xmp ymp];
waypoints = Pmp;

end

function [pub, msg] = publish_twist_command(v, w, topicName)
pub = rospublisher(topicName, 'geometry_msgs/Twist','DataFormat','struct');
msg = rosmessage(pub);
msg.Linear.X = v;
msg.Angular.Z = w;
end