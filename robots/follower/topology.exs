# The follower robot's topology (§06 input): hub → flat NODE id (§03).
#
# Matches the design's example: the IMU senses on node 0x02, the wheel motor
# acts on node 0x05. NODE is whole-tree-unique and never a path; 0x00 is the
# reserved broadcast/e-stop id and the host is logical id 0 (above the tree).
%{
  imu: 0x02,
  motor: 0x05
}
