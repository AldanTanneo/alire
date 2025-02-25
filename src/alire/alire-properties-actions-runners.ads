with Alire.Utils;

package Alire.Properties.Actions.Runners with Preelaborate is

   --  A Run action executes custom commands

   type Run (<>) is new Action with private;
   --  Encapsulates the execution of an external command

   type Builtin_Command is (Alire_Test_Runner);
   type Command_Kind is (Builtin, Shell_Command);

   type Action_Command (Kind : Command_Kind := Builtin) is record
      case Kind is
         when Builtin =>
            Builtin : Builtin_Command;
         when Shell_Command =>
            Cmd : AAA.Strings.Vector;
      end case;
   end record;

   function Command_Line   (This : Run) return Action_Command;
   function Working_Folder (This : Run) return String;

   overriding
   function To_TOML (This : Run) return TOML.TOML_Value;

   function From_TOML (From : TOML_Adapters.Key_Queue)
                       return Conditional.Properties;

private

   subtype Action_Name is String with Dynamic_Predicate =>
     (for all Char of Action_Name =>
        Char in 'a' .. 'z' | '0' .. '9' | '-')
     and then Action_Name'Length > 1
     and then Action_Name (Action_Name'First) in 'a' .. 'z'
     and then Action_Name (Action_Name'Last) /= '-'
     and then (for all I in Action_Name'First .. Action_Name'Last - 1 =>
                 (if Action_Name (I) = '-'
                  then Action_Name (I + 1) /= '-'));

   type Run (Moment : Moments;
             Cmd_Kind : Command_Kind;
             Folder_Len : Natural;
             Name_Len : Natural)
   is new Action (Moment) with record
      Name           : String (1 .. Name_Len);
      --  Optional, except for custom actions, which require a name.

      Command        : Action_Command (Cmd_Kind);
      Working_Folder : Any_Path (1 .. Folder_Len);
   end record
     with Type_Invariant =>
      (Name in "" | Action_Name)
     and then
       (if Moment = On_Demand then Name /= "");

   function Image (Cmd : Action_Command) return String is
      (case Cmd.Kind is
         when Builtin => AAA.Strings.To_Lower_Case (Cmd.Builtin'Image),
         when Shell_Command => Cmd.Cmd.Flatten);

   overriding
   function Image (This : Run) return String
   is (AAA.Strings.To_Mixed_Case (This.Moment'Img)
       & (if This.Name /= "" then " (" & This.Name & ")" else "")
       & " run: " & Image (This.Command)
       & " (from ${CRATE_ROOT}/" & This.Working_Folder & ")");

   overriding
   function To_YAML (This : Run) return String
   is (AAA.Strings.To_Mixed_Case (This.Moment'Img) & " run: <project>" &
        (if This.Working_Folder /= "" then "/" else "") &
        This.Working_Folder & "/" & Image (This.Command));

   function New_Run (Moment         : Moments;
                     Name           : String;
                     Command        : Action_Command;
                     Working_Folder : Any_Path)
                     return Run'Class
   --  Working folder will be entered for execution
   --  Relative command-line must consider being in working folder
   is
     (Run'
        (Moment,
         Command.Kind,
         Working_Folder'Length,
         Name'Length,
         Name,
         Command,
         Utils.To_Native (Working_Folder)));

   function Command_Line (This : Run) return Action_Command
   is (This.Command);

   function Working_Folder (This : Run) return String
   is (This.Working_Folder);

end Alire.Properties.Actions.Runners;
