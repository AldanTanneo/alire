with Ada.Command_Line;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Text_IO; use Ada.Text_IO;

--  To add a command: update the dispatch table below

with Alr.Bootstrap;
with Alr.Commands.Build;
with Alr.Commands.Clean;
with Alr.Commands.Dev;
with Alr.Commands.Get;
with Alr.Commands.Help;
with Alr.Commands.Reserved;
with Alr.Commands.Update;
with Alr.Commands.Upgrade;
with Alr.Devel;
with Alr.OS;

with GNAT.OS_Lib;

package body Alr.Commands is

   Wrong_Command_Arguments : exception;

   use GNAT.Command_Line;

   Dispatch_Table : constant array (Cmd_Names) of access Command'Class :=
                      (Cmd_Build   => new Build.Command,
                       Cmd_Clean   => new Clean.Command,
                       Cmd_Dev     => new Dev.Command,
                       Cmd_Get     => new Get.Command,
                       Cmd_Help    => new Help.Command,
                       Cmd_Update  => new Update.Command,
                       Cmd_Upgrade => new Upgrade.Command,
                       others      => new Reserved.Command);

   Log_Verbose : aliased Boolean := False;
   Log_Debug   : aliased Boolean := False;

   -----------
   -- Image --
   -----------

   function Image (N : Cmd_Names) return String is
      Pre : constant String := To_Lower (N'Img);
   begin
      return Pre (Pre'First + 4 .. Pre'Last);
   end Image;

   -------------------------
   -- Set_Global_Switches --
   -------------------------

   procedure Set_Global_Switches (Config : in out GNAT.Command_Line.Command_Line_Configuration) is
   begin
      Define_Switch (Config,
                     Log_Verbose'Access,
                     "-v",
                     Help => "Be more verbose.");

      Define_Switch (Config,
                     Log_Debug'Access,
                     "-d",
                     Help => "Be even more verbose (implies -v).");
   end Set_Global_Switches;

   -------------
   -- Bailout --
   -------------

   procedure Bailout (Code : Integer := 0) is
   begin
      GNAT.OS_Lib.OS_Exit (Code);
   end Bailout;

   --------------------------
   -- Create_Alire_Folders --
   --------------------------

   procedure Create_Alire_Folders is
   begin
      OS.Create_Folder (OS.Config_Folder);
      OS.Create_Folder (OS.Cache_Folder);
      OS.Create_Folder (OS.Projects_Folder);
   end Create_Alire_Folders;

   -----------------------------
   -- Display_Help_Workaround --
   -----------------------------

   procedure Display_Help_Workaround (Config : GNAT.Command_Line.Command_Line_Configuration) is
   begin
      GNAT.Command_Line.Display_Help (Config);
   exception
      when Storage_Error =>
         -- Workaround for bug up to GNAT 2017
         -- Probably not great, but at this point we are exiting anyway
         null;
   end Display_Help_Workaround;

   -------------------
   -- Display_Usage --
   -------------------

   procedure Display_Usage is
   begin
      Put_Line ("Ada Library Repository manager (alr)");
      Put_Line ("Usage : alr command [switches] [arguments]");

      New_Line;

      Display_Valid_Commands;

      New_Line;
      Put_Line ("Use ""alr help [command]"" for more information about a command.");
      New_Line;
   end Display_Usage;

   -------------------
   -- Display_Usage --
   -------------------

   procedure Display_Usage (Cmd : Cmd_Names) is
      Config : Command_Line_Configuration;
   begin
      Set_Usage (Config,
                 Image (Cmd) & " [options] " & Dispatch_Table (Cmd).Usage_Custom_Parameters,
                 Help => "Help for " & Image (Cmd));

      Set_Global_Switches (Config);

      Dispatch_Table (Cmd).Setup_Switches (Config);

      Display_Help_Workaround (Config);

      Dispatch_Table (Cmd).Display_Help_Details;
   end Display_Usage;

   ------------------
   -- Longest_Name --
   ------------------

   function Longest_Name return Positive is
   begin
      return Max : Positive := 1 do
         for Cmd in Cmd_Names'Range loop
            Max := Positive'Max (Max, Image (Cmd)'Length);
         end loop;
      end return;
   end Longest_Name;

   ----------------------------
   -- Display_Valid_Commands --
   ----------------------------

   procedure Display_Valid_Commands is
      Tab : constant String (1 .. 8) := (others => ' ');
      Max : constant Positive := Longest_Name + 1;
      Pad : String (1 .. Max);
   begin
      Put_Line ("Valid commands: ");
      New_Line;
      for Cmd in Cmd_Names'Range loop
         if Cmd /= Cmd_Dev or else Alr.Devel.Enabled then
            Put (Tab);

            Pad := (others => ' ');
            Pad (Pad'First .. Pad'First + Image (Cmd)'Length - 1) := Image (Cmd);
            Put (Pad);

            Put (Dispatch_Table (Cmd).Short_Description);
            New_Line;
         end if;
      end loop;
   end Display_Valid_Commands;

   --------------------------
   -- Ensure_Valid_Project --
   --------------------------

   procedure Ensure_Valid_Project is
   begin
      Bootstrap.Check_Rebuild_Respawn; -- Might respawn and not return
      Project.Check_Valid;             -- Might raise Command_Failed
   end Ensure_Valid_Project;

   -------------
   -- Execute --
   -------------

   procedure Execute is
      use Ada.Command_Line;

      Cmd : Cmd_Names;
   begin
      if Argument_Count < 1 or else Argument (1) = "-h" or else Argument (1) = "--help" then
         Display_Usage;
         return;
      else
         declare
            Pre_Cmd : constant String := Argument (1);
         begin
            Cmd := Cmd_Names'Value (Pre_Cmd (Pre_Cmd'First + 4 .. Pre_Cmd'Last));
         exception
            when Constraint_Error =>
               Put_Line ("Unrecognized command: " & Argument (1));
               New_Line;
               Display_Usage;
               Bailout (1);
         end;

         Create_Alire_Folders;

         Execute_By_Name (Cmd);
      end if;
   end Execute;

   ---------------------
   -- Execute_Command --
   ---------------------

   procedure Execute_By_Name (Cmd : Cmd_Names) is
      Config : Command_Line_Configuration;
   begin
      Set_Global_Switches (Config);

      Define_Switch (Config, "-h", "--help", "Show this hopefully helpful help.");
      --  A lie to avoid the aforementioned bug

      --  Fill switches and execute
      Dispatch_Table (Cmd).Setup_Switches (Config);
      begin
         Getopt (Config); -- Parses command line switches

         if Log_Debug then
            Alire.Verbosity := Debug;
         elsif Log_Verbose then
            Alire.Verbosity := Verbose;
         end if;

         Put_Line (Image (Cmd) & ":");
         Dispatch_Table (Cmd).Execute;
      exception
         when Exit_From_Command_Line | Invalid_Switch | Invalid_Parameter =>
            --  Getopt has already displayed some help
            Bailout (1);

         when Wrong_Command_Arguments =>
            Display_Usage (Cmd);
            Bailout (1);

         when Command_Failed =>
            Bailout (1);
      end;
   end Execute_By_Name;

   -------------------
   -- Last_Argument --
   -------------------

   function Last_Argument return String is
      use Ada.Command_Line;
   begin
      if Argument_Count < 2 then
         raise Wrong_Command_Arguments;
      else
         return Last : constant String := Argument (Argument_Count) do
            if Last (Last'First) = '-' then
               raise Wrong_Command_Arguments;
            end if;
         end return;
      end if;
   end Last_Argument;

end Alr.Commands;