;- Top
; -----------------------------------------------------------------------------
; PureBasic Documentation Index
; -----------------------------------------------------------------------------
; HOW IT WORKS
; Select the PureBasic source root, scan Documentation\English recursively and
; read every .txt source with the same tag rules as the official HelpTool.
;  - Library files (@Library + @Function): one entry per @Function.
;  - Reference files (@Title + @Syntax): one entry per @Syntax block.
;    Single block: the name is the @Title (e.g. "For : Next").
;    Several blocks: the name is the first @Keyword of the syntax (e.g. SizeOf).
;    All @Keyword words of the block are searchable.
;  - Only real block tags end a field. Inline tags (@@Func, @#Const, @Keyword,
;    @Link...) are text and are cleaned. @Code, @FormatIf and non-Windows @OS
;    blocks are skipped. Lines starting with ';' are comments.
;  - Constants: "@#PB_Name : text" lines in the docs give the constant, its text
;    and where it is documented. PureBasicIDE\ConstantsData.pbi gives the
;    functions (and parameter numbers) that use it. Both are merged in one
;    "Constants" group.
; The result is one standalone HTML file: collapsible groups, ranked live search
; (all words must match, "exact words", lib:gadget, ref:, const:), links to the
; GitHub source line. With #CreateJSON = #True a compact .json copy is written too.
; A bar of library chips above the table restricts the results to one or several
; libraries (combined with the search); each chip shows the number of matches.
; In the Constants group, "Used by" is grouped by function (BodyPick(2,5)) and the
; HTML shows only the first #MaxUsedByShown functions followed by "..." (the JSON
; keeps the full list; the search always uses all function names).
; The HTML head and script are stored in DataSection at the end of this file.
; -----------------------------------------------------------------------------

EnableExplicit

; ---- Constants --------------------------------------------------------------

#CreateJSON = #True   ; #True: also write a compact .json file next to the .html

#ReferenceGroup$  = "Reference"
#ConstantGroup$   = "Constants"
#GitHubBase$      = "https://github.com/fantaisie-software/purebasic/blob/devel/"
#DocsFolder$      = "Documentation/English/"
#ConstantsDataFile$ = "PureBasicIDE/ConstantsData.pbi"   ; relative to the source root
#MaxDefinedIn     = 8   ; max functions listed in "Defined in" for one constant
#MaxUsedByShown   = 5   ; max functions shown in "Used by" in the HTML (the JSON keeps all)

; Block tags: they end the current field (list taken from the official HelpTool).
#BlockTags$ = ",library,librarydestination,title,function,syntax,description,parameter,optionalparameter,noparameters,returnvalue,noreturnvalue,remarks,example,examplefile,code,endcode,seealso,supportedos,os,endos,commandlist,overview,section,formatif,formatelse,formatendif,html,endhtml,fixedfont,endfixedfont,indent,endindent,image,deprecated,"

; Inline tags: used inside the text (only to report unknown tags in Debug).
#InlineTags$ = ",linebreak,red,green,blue,orange,bold,underline,constantcolor,functioncolor,keyword,internetlink,link,librarylink,fastlink,referencelink,mainguidelink,"

Enumeration 1
  #FileInput
  #FileOutput
  #FileJSON
EndEnumeration

Enumeration
  #FieldNone
  #FieldDescription
  #FieldReturnValue
  #FieldSyntax
EndEnumeration

Enumeration
  #KindFunction
  #KindReference
  #KindConstant
EndEnumeration

; ---- Structures and globals -------------------------------------------------

Structure DocEntry
  Name$
  Signature$       ; syntax lines separated by #LF$
  Library$         ; group in the HTML (library name or "Reference")
  Chapter$         ; reference only: @Title of the source file
  Keywords$        ; reference only: @Keyword words separated by "|"
  Description$
  ReturnValue$
  DefinedIn$       ; constant only: functions that document it
  UsedBy$          ; constant only: "Function(param)" list from ConstantsData.pbi
  RelativePath$    ; path relative to the repository root
  SortKey$
  SourceLine.i
  Kind.i
  FileId.i
EndStructure

; Working data of one constant, merged from the docs and from ConstantsData.pbi.
Structure ConstInfo
  Name$
  Description$
  DefinedIn$       ; "|" separated function names
  DefinedInMore.i  ; #True when the list was cut at #MaxDefinedIn
  UsedBy$          ; ", " separated "Function(param)"
  Keywords$        ; "|" separated function names (searchable)
  RelativePath$
  SourceLine.i
EndStructure

Global SourceRoot$, EnglishPath$, OutputPath$
Global CurrentLibrary$, FileTitle$, FileBaseName$, CurrentRelative$, Separators$
Global CurrentField, CurrentFileId, FileCounter, InEntry, InCode, InFormat, SkipOS, ScanPos
Global FileEntryCount, FileRefCount, EntryCount, FunctionCount, ReferenceCount, ConstantCount, SkippedPages
Global ConstLastKey$, ConstContinue
Global NewList Entries.DocEntry()
Global NewMap Consts.ConstInfo()
Global NewMap UnknownTags()

; Characters that end an unquoted tag parameter (same set as the HelpTool).
Separators$ = " .,;:()[]{}>@/" + Chr(34) + Chr(160)

; ---- Small helpers ----------------------------------------------------------

; Write one UTF-8 line to the output file.
Procedure Out(Text$)
  WriteStringN(#FileOutput, Text$, #PB_UTF8)
EndProcedure

; Add a trailing backslash to a folder path.
Procedure.s EnsureTrailingSlash(Path$)
  If Right(Path$, 1) <> "\" And Right(Path$, 1) <> "/"
    Path$ + "\"
  EndIf
  ProcedureReturn Path$
EndProcedure

; Escape text before writing it into HTML.
Procedure.s EscapeHTML(Text$)
  Text$ = ReplaceString(Text$, "&", "&amp;")
  Text$ = ReplaceString(Text$, "<", "&lt;")
  Text$ = ReplaceString(Text$, ">", "&gt;")
  Text$ = ReplaceString(Text$, Chr(34), "&quot;")
  Text$ = ReplaceString(Text$, "'", "&#39;")
  ProcedureReturn Text$
EndProcedure

; Encode characters that can break a GitHub URL path.
Procedure.s EncodeURLPath(Path$)
  Path$ = ReplaceString(Path$, "%", "%25")
  Path$ = ReplaceString(Path$, " ", "%20")
  Path$ = ReplaceString(Path$, "#", "%23")
  Path$ = ReplaceString(Path$, "?", "%3F")
  Path$ = ReplaceString(Path$, "[", "%5B")
  Path$ = ReplaceString(Path$, "]", "%5D")
  Path$ = ReplaceString(Path$, "\", "/")
  ProcedureReturn Path$
EndProcedure

; True for a letter character code.
Procedure IsLetter(Code)
  ProcedureReturn Bool((Code >= 'a' And Code <= 'z') Or (Code >= 'A' And Code <= 'Z'))
EndProcedure

; True for a letter, digit or underscore character code.
Procedure IsNameChar(Code)
  ProcedureReturn Bool(IsLetter(Code) Or (Code >= '0' And Code <= '9') Or Code = '_')
EndProcedure

; Replace line breaks and tabs by spaces, trim and collapse double spaces.
Procedure.s CleanText(Text$)
  Text$ = ReplaceString(Text$, #CR$, " ")
  Text$ = ReplaceString(Text$, #LF$, " ")
  Text$ = ReplaceString(Text$, #TAB$, " ")
  Text$ = ReplaceString(Text$, Chr(160), " ")
  Text$ = Trim(Text$)
  While FindString(Text$, "  ")
    Text$ = ReplaceString(Text$, "  ", " ")
  Wend
  ProcedureReturn Text$
EndProcedure

; ---- Inline tag cleaning ----------------------------------------------------

; Read one tag parameter (quoted or word) at the global ScanPos and move ScanPos after it.
Procedure.s ReadParam(Text$)
  Protected Start, Result$
  
  While Mid(Text$, ScanPos, 1) = " "
    ScanPos + 1
  Wend
  
  If Mid(Text$, ScanPos, 1) = Chr(34)
    Start = ScanPos + 1
    ScanPos = FindString(Text$, Chr(34), Start)
    If ScanPos = 0
      Result$ = Mid(Text$, Start)
      ScanPos = Len(Text$) + 1
    Else
      Result$ = Mid(Text$, Start, ScanPos - Start)
      ScanPos + 1
    EndIf
  Else
    Start = ScanPos
    While ScanPos <= Len(Text$) And FindString(Separators$, Mid(Text$, ScanPos, 1)) = 0
      ScanPos + 1
    Wend
    Result$ = Mid(Text$, Start, ScanPos - Start)
  EndIf
  ProcedureReturn Result$
EndProcedure

; Remove inline tags: @@Func -> Func, @#Const -> #Const, @Keyword X -> X, @Link "a" "b" -> b.
Procedure.s CleanInline(Text$)
  Protected Result$, Tag$, Param1$, Param2$
  Protected Pos = 1, At, Start, Length = Len(Text$)
  
  If FindString(Text$, "@") = 0
    ProcedureReturn Text$
  EndIf
  
  Repeat
    At = FindString(Text$, "@", Pos)
    If At = 0
      Result$ + Mid(Text$, Pos)
      Break
    EndIf
    Result$ + Mid(Text$, Pos, At - Pos)
    Pos = At + 1
    
    If Mid(Text$, Pos, 1) = "@" Or Mid(Text$, Pos, 1) = "#"
      ; @@Function or @#Constant: keep the name only (constants keep the #).
      If Mid(Text$, Pos, 1) = "#"
        Result$ + "#"
      EndIf
      Pos + 1
      Start = Pos
      While Pos <= Length And IsNameChar(Asc(Mid(Text$, Pos, 1)))
        Pos + 1
      Wend
      Result$ + Mid(Text$, Start, Pos - Start)
    Else
      Start = Pos
      While Pos <= Length And IsLetter(Asc(Mid(Text$, Pos, 1)))
        Pos + 1
      Wend
      Tag$ = LCase(Mid(Text$, Start, Pos - Start))
      ScanPos = Pos
      Select Tag$
        Case "linebreak"
          Result$ + " "
        Case "keyword", "bold", "underline", "red", "green", "blue", "orange", "constantcolor", "functioncolor", "fastlink"
          Result$ + ReadParam(Text$)
        Case "link", "referencelink", "librarylink", "mainguidelink", "internetlink"
          Param1$ = ReadParam(Text$)
          Param2$ = ReadParam(Text$)
          If Param2$ = ""
            Param2$ = Param1$
          EndIf
          Result$ + Param2$
        Default
          Result$ + "@" + Mid(Text$, Start, Pos - Start)
      EndSelect
      Pos = ScanPos
    EndIf
  ForEver
  ProcedureReturn Result$
EndProcedure

; Add the @Keyword words found in a raw syntax line to a "|" separated list (no duplicates).
Procedure.s AddKeywords(Existing$, Raw$)
  Protected Pos = 1, At, Token$
  
  Repeat
    At = FindString(Raw$, "@Keyword", Pos, #PB_String_NoCase)
    If At = 0
      Break
    EndIf
    ScanPos = At + 8
    Token$ = Trim(ReadParam(Raw$))
    If Token$ <> "" And FindString("|" + Existing$ + "|", "|" + Token$ + "|", 1, #PB_String_NoCase) = 0
      If Existing$ <> ""
        Existing$ + "|"
      EndIf
      Existing$ + Token$
    EndIf
    Pos = ScanPos
  ForEver
  ProcedureReturn Existing$
EndProcedure

; Return the lower case block tag of a line ("" if the line is text, even if it starts with '@').
Procedure.s BlockDirective(Trimmed$)
  Protected Tag$
  
  If Left(Trimmed$, 1) <> "@"
    ProcedureReturn ""
  EndIf
  Tag$ = LCase(Mid(StringField(Trimmed$, 1, " "), 2))
  If FindString(#BlockTags$, "," + Tag$ + ",")
    ProcedureReturn Tag$
  EndIf
  ProcedureReturn ""
EndProcedure

; Count a text line that starts with an unknown @tag (reported in Debug at the end).
Procedure NoteUnknownTag(Trimmed$)
  Protected Pos = 2, Tag$
  
  If Mid(Trimmed$, 2, 1) = "@" Or Mid(Trimmed$, 2, 1) = "#"
    ProcedureReturn
  EndIf
  While Pos <= Len(Trimmed$) And IsLetter(Asc(Mid(Trimmed$, Pos, 1)))
    Pos + 1
  Wend
  Tag$ = LCase(Mid(Trimmed$, 2, Pos - 2))
  If FindString(#InlineTags$, "," + Tag$ + ",") = 0
    UnknownTags("@" + Tag$) + 1
  EndIf
EndProcedure

; ---- Entry building ---------------------------------------------------------

; Function name = last word before the first '(' ("Result = ButtonGadget(...)" -> ButtonGadget).
Procedure.s FunctionName(Value$)
  Protected Pos, Head$
  
  Pos = FindString(Value$, "(")
  If Pos
    Head$ = Trim(Left(Value$, Pos - 1))
  Else
    Head$ = Trim(Value$)
  EndIf
  ProcedureReturn StringField(Head$, CountString(Head$, " ") + 1, " ")
EndProcedure

; Append a new empty entry at the end of the list and make it the current one.
Procedure NewEntry(Kind, LineNo)
  LastElement(Entries())
  AddElement(Entries())
  Entries()\Kind = Kind
  Entries()\FileId = CurrentFileId
  Entries()\RelativePath$ = CurrentRelative$
  Entries()\SourceLine = LineNo
  InEntry = #True
  CurrentField = #FieldNone
EndProcedure

; Append one text line (tags cleaned) to the field being collected.
Procedure AppendFieldLine(Line$)
  Protected Clean$
  
  Clean$ = CleanText(CleanInline(Line$))
  Select CurrentField
    Case #FieldSyntax
      Entries()\Keywords$ = AddKeywords(Entries()\Keywords$, Line$)
      If Clean$ <> ""
        If Entries()\Signature$ <> ""
          Entries()\Signature$ + #LF$
        EndIf
        Entries()\Signature$ + Clean$
      EndIf
      
    Case #FieldDescription
      If Clean$ <> ""
        If Entries()\Description$ <> ""
          Entries()\Description$ + " "
        EndIf
        Entries()\Description$ + Clean$
      EndIf
      
    Case #FieldReturnValue
      If Clean$ <> ""
        If Entries()\ReturnValue$ <> ""
          Entries()\ReturnValue$ + " "
        EndIf
        Entries()\ReturnValue$ + Clean$
      EndIf
  EndSelect
EndProcedure

; Close the current entry: drop it if unusable, otherwise count it.
Procedure FinishEntry()
  If InEntry = #False
    ProcedureReturn
  EndIf
  InEntry = #False
  CurrentField = #FieldNone
  
  If Entries()\Kind = #KindFunction
    If Entries()\Name$ = ""
      DeleteElement(Entries())
    Else
      If Entries()\Library$ = ""
        Entries()\Library$ = FileBaseName$
      EndIf
      If Entries()\Signature$ = ""
        Entries()\Signature$ = Entries()\Name$
      EndIf
      FunctionCount + 1
      EntryCount + 1
      FileEntryCount + 1
    EndIf
  Else
    If Entries()\Signature$ = ""
      DeleteElement(Entries())
    Else
      ReferenceCount + 1
      EntryCount + 1
      FileEntryCount + 1
      FileRefCount + 1
    EndIf
  EndIf
EndProcedure

; Start a library function entry (@Function line).
Procedure StartFunction(Value$, LineNo)
  NewEntry(#KindFunction, LineNo)
  Entries()\Name$ = FunctionName(Value$)
  Entries()\Signature$ = CleanText(CleanInline(Value$))
  Entries()\Library$ = CurrentLibrary$
EndProcedure

; Start a reference entry (@Syntax line). A second @Syntax before any description joins the same entry.
Procedure StartSyntax(Value$, LineNo)
  Protected Merge = #False
  
  If InEntry
    If Entries()\Kind = #KindReference And Entries()\Description$ = "" And Entries()\ReturnValue$ = ""
      Merge = #True
    EndIf
  EndIf
  
  If Merge = #False
    FinishEntry()
    NewEntry(#KindReference, LineNo)
    Entries()\Library$ = #ReferenceGroup$
  EndIf
  
  CurrentField = #FieldSyntax
  If Value$ <> ""
    AppendFieldLine(Value$)
  EndIf
EndProcedure

; ---- Constants ---------------------------------------------------------------

; Merge the items of NewItems$ into Existing$ (both use Sep$ as separator, no duplicates).
Procedure.s MergeItems(Existing$, NewItems$, Sep$)
  Protected I, Count, Item$
  
  Count = CountString(NewItems$, Sep$) + 1
  For I = 1 To Count
    Item$ = StringField(NewItems$, I, Sep$)
    If Item$ <> "" And FindString(Sep$ + Existing$ + Sep$, Sep$ + Item$ + Sep$) = 0
      If Existing$ <> ""
        Existing$ + Sep$
      EndIf
      Existing$ + Item$
    EndIf
  Next
  ProcedureReturn Existing$
EndProcedure

; Register a documented constant from a line like "@#PB_Button_Right : description".
Procedure TryConstantDefinition(Trimmed$, LineNo)
  Protected Pos = 3, Items, Name$, Rest$, Key$, Where$, Text$
  
  ConstContinue = #False
  While Pos <= Len(Trimmed$) And IsNameChar(Asc(Mid(Trimmed$, Pos, 1)))
    Pos + 1
  Wend
  Name$ = "#" + Mid(Trimmed$, 3, Pos - 3)
  Rest$ = LTrim(Mid(Trimmed$, Pos))
  If Len(Name$) < 2 Or Left(Rest$, 1) <> ":"
    ProcedureReturn
  EndIf
  Text$ = CleanText(CleanInline(Mid(Rest$, 2)))
  
  ; Function (or page) that documents the constant.
  If InEntry
    If Entries()\Kind = #KindFunction
      Where$ = Entries()\Name$
    EndIf
  EndIf
  If Where$ = ""
    Where$ = FileTitle$
  EndIf
  If Where$ = ""
    Where$ = CurrentLibrary$
  EndIf
  If Where$ = ""
    Where$ = FileBaseName$
  EndIf
  
  Key$ = LCase(Name$)
  If FindMapElement(Consts(), Key$) = 0
    AddMapElement(Consts(), Key$)
    Consts()\Name$ = Name$
    Consts()\Description$ = Text$
    Consts()\RelativePath$ = CurrentRelative$
    Consts()\SourceLine = LineNo
    ConstLastKey$ = Key$
    ConstContinue = #True
  ElseIf Consts()\Description$ = "" And Text$ <> ""
    ; An earlier definition had no text: keep this one (text and link).
    Consts()\Description$ = Text$
    Consts()\RelativePath$ = CurrentRelative$
    Consts()\SourceLine = LineNo
    ConstLastKey$ = Key$
    ConstContinue = #True
  EndIf
  
  ; Keep the first #MaxDefinedIn functions that document the constant.
  If FindString("|" + Consts()\DefinedIn$ + "|", "|" + Where$ + "|") = 0
    If Consts()\DefinedIn$ <> ""
      Items = CountString(Consts()\DefinedIn$, "|") + 1
    EndIf
    If Items < #MaxDefinedIn
      Consts()\DefinedIn$ = MergeItems(Consts()\DefinedIn$, Where$, "|")
    Else
      Consts()\DefinedInMore = #True
    EndIf
  EndIf
EndProcedure

; Add a continuation line to the text of the constant defined just before (max 300 characters).
Procedure AppendConstantLine(Trimmed$)
  Protected Text$
  
  If FindMapElement(Consts(), ConstLastKey$) = 0 Or Len(Consts()\Description$) >= 300
    ConstContinue = #False
    ProcedureReturn
  EndIf
  Text$ = CleanText(CleanInline(Trimmed$))
  If Text$ <> ""
    If Consts()\Description$ <> ""
      Consts()\Description$ + " "
    EndIf
    Consts()\Description$ + Text$
  EndIf
EndProcedure

; Handle one source line (Tag$ is "" for text lines).
Procedure HandleLine(Tag$, Value$, Trimmed$, LineNumber)
  Protected OSName$
  
  If Tag$ <> ""
    ConstContinue = #False
  EndIf
  
  Select Tag$
    Case "library"
      FinishEntry()
      CurrentLibrary$ = CleanText(CleanInline(Value$))
      
    Case "title"
      FinishEntry()
      FileTitle$ = CleanText(CleanInline(Value$))
      
    Case "function"
      FinishEntry()
      SkipOS = #False
      StartFunction(Value$, LineNumber)
      
    Case "syntax"
      StartSyntax(Value$, LineNumber)
      
    Case "description"
      If InEntry
        CurrentField = #FieldDescription
      Else
        CurrentField = #FieldNone
      EndIf
      
    Case "returnvalue"
      If InEntry
        CurrentField = #FieldReturnValue
        If Value$ <> ""
          AppendFieldLine(Value$)
        EndIf
      Else
        CurrentField = #FieldNone
      EndIf
      
    Case "noreturnvalue"
      If InEntry
        Entries()\ReturnValue$ = "None"
      EndIf
      CurrentField = #FieldNone
      
    Case "os"
      ; Keep Windows and All blocks, skip the others.
      OSName$ = LCase(Value$)
      SkipOS = Bool(OSName$ <> "windows" And OSName$ <> "all")
      
    Case "endos"
      SkipOS = #False
      
    Case "commandlist", "supportedos"
      SkipOS = #False
      CurrentField = #FieldNone
      
    Case "code"
      InCode = #True
      
    Case "formatif", "html"
      InFormat = #True
      
    Case "indent", "endindent", "fixedfont", "endfixedfont", "image", "formatelse", "formatendif", "endcode", "endhtml"
      ; Layout tags: they do not end the current field.
      
    Case ""
      If Left(Trimmed$, 1) = "@"
        NoteUnknownTag(Trimmed$)
      EndIf
      
      ; "@#PB_Name : text" defines a constant; the following text lines continue its text.
      If Left(Trimmed$, 2) = "@#"
        TryConstantDefinition(Trimmed$, LineNumber)
      ElseIf ConstContinue
        If Trimmed$ <> "" And Left(Trimmed$, 1) <> "@"
          AppendConstantLine(Trimmed$)
        Else
          ConstContinue = #False
        EndIf
      EndIf
      
      If InEntry And CurrentField <> #FieldNone And Trimmed$ <> ""
        AppendFieldLine(Trimmed$)
      EndIf
      
    Default
      CurrentField = #FieldNone
  EndSelect
EndProcedure

; Name the reference entries of the current file (option C: one block = @Title, several = first @Keyword).
Procedure NameReferenceEntries()
  Protected Count, Index, Title$
  
  If FileRefCount = 0
    ProcedureReturn
  EndIf
  
  Title$ = FileTitle$
  If Title$ = ""
    Title$ = FileBaseName$
  EndIf
  
  ForEach Entries()
    If Entries()\FileId = CurrentFileId And Entries()\Kind = #KindReference
      Count + 1
    EndIf
  Next
  
  ForEach Entries()
    If Entries()\FileId = CurrentFileId And Entries()\Kind = #KindReference
      Index + 1
      Entries()\Chapter$ = Title$
      If Count = 1
        Entries()\Name$ = Title$
      Else
        Entries()\Name$ = StringField(Entries()\Keywords$, 1, "|")
        If Entries()\Name$ = ""
          Entries()\Name$ = Title$ + " #" + Str(Index)
        EndIf
      EndIf
    EndIf
  Next
EndProcedure

; ---- File scanning ----------------------------------------------------------

; Read one documentation text file and extract its entries.
Procedure ParseDocumentationFile(FilePath$)
  Protected FileNumber, LineNumber, Format, Process
  Protected Line$, Trimmed$, Tag$, Value$
  
  FileNumber = ReadFile(#FileInput, FilePath$)
  If FileNumber = 0
    ProcedureReturn
  EndIf
  
  ; ReadStringFormat skips the BOM; sources without BOM are read as UTF-8.
  Format = ReadStringFormat(#FileInput)
  If Format = #PB_Ascii
    Format = #PB_UTF8
  EndIf
  
  FileCounter + 1
  CurrentFileId = FileCounter
  CurrentRelative$ = #DocsFolder$ + ReplaceString(Mid(FilePath$, Len(EnglishPath$) + 1), "\", "/")
  FileBaseName$ = GetFilePart(FilePath$, #PB_FileSystem_NoExtension)
  CurrentLibrary$ = ""
  FileTitle$ = ""
  CurrentField = #FieldNone
  InEntry = #False
  InCode = #False
  InFormat = #False
  SkipOS = #False
  FileEntryCount = 0
  FileRefCount = 0
  ConstContinue = #False
  LineNumber = 0
  
  While Eof(#FileInput) = 0
    Line$ = ReadString(#FileInput, Format)
    LineNumber + 1
    If LineNumber = 1
      Line$ = ReplaceString(Line$, Chr(65279), "")
    EndIf
    Line$ = ReplaceString(Line$, #TAB$, " ")
    Trimmed$ = Trim(Line$)
    Tag$ = BlockDirective(Trimmed$)
    Value$ = ""
    If Tag$ <> ""
      Value$ = Trim(Mid(Trimmed$, Len(StringField(Trimmed$, 1, " ")) + 1))
    EndIf
    
    ; Decide if the line must be skipped (code, raw HTML, comment, other OS).
    Process = #True
    If InCode
      If Tag$ = "endcode"
        InCode = #False
      EndIf
      Process = #False
    ElseIf InFormat
      If Tag$ = "formatendif" Or Tag$ = "endhtml"
        InFormat = #False
      EndIf
      Process = #False
    ElseIf Left(Line$, 1) = ";"
      Process = #False
    ElseIf SkipOS
      If Tag$ <> "os" And Tag$ <> "endos" And Tag$ <> "commandlist" And Tag$ <> "supportedos" And Tag$ <> "function"
        Process = #False
      EndIf
    EndIf
    
    If Process
      HandleLine(Tag$, Value$, Trimmed$, LineNumber)
    EndIf
  Wend
  
  FinishEntry()
  CloseFile(#FileInput)
  NameReferenceEntries()
  
  ; A page with a @Title but no @Syntax gives no entry (prose chapter).
  If FileTitle$ <> "" And FileEntryCount = 0
    SkippedPages + 1
    Debug "No @Syntax, skipped: " + CurrentRelative$
  EndIf
EndProcedure

; Recursively scan a folder for .txt documentation sources.
Procedure ScanDirectory(Path$)
  Protected DirectoryNumber
  Protected Name$, FullPath$
  
  DirectoryNumber = ExamineDirectory(#PB_Any, Path$, "*")
  If DirectoryNumber = 0
    ProcedureReturn
  EndIf
  
  While NextDirectoryEntry(DirectoryNumber)
    Name$ = DirectoryEntryName(DirectoryNumber)
    
    If Name$ <> "." And Name$ <> ".."
      FullPath$ = Path$ + Name$
      If DirectoryEntryType(DirectoryNumber) = #PB_DirectoryEntry_Directory
        ScanDirectory(EnsureTrailingSlash(FullPath$))
      ElseIf LCase(GetExtensionPart(Name$)) = "txt"
        ParseDocumentationFile(FullPath$)
      EndIf
    EndIf
  Wend
  
  FinishDirectory(DirectoryNumber)
EndProcedure

; ---- ConstantsData.pbi ---------------------------------------------------------

; Add one function parameter use to a constant (created if the docs did not define it).
Procedure RegisterConstantUse(Token$, Func$, ParamNo$, LineNo)
  Protected Key$ = LCase(Token$)
  
  If FindMapElement(Consts(), Key$) = 0
    AddMapElement(Consts(), Key$)
  EndIf
  Consts()\Name$ = Token$   ; the IDE file has the official upper/lower case
  If Consts()\RelativePath$ = ""
    Consts()\RelativePath$ = #ConstantsDataFile$
    Consts()\SourceLine = LineNo
  EndIf
  Consts()\UsedBy$ = MergeItems(Consts()\UsedBy$, Func$ + "(" + ParamNo$ + ")", ", ")
  Consts()\Keywords$ = MergeItems(Consts()\Keywords$, Func$, "|")
EndProcedure

; Read ConstantsData.pbi: lines Data$ "Function,ParamNo,#Const,#Const,..." (Windows branch only, no nested CompilerIf).
Procedure ParseConstantsData(FilePath$)
  Protected Format, LineNo, Active = #True, Quote1, Quote2, I, Count
  Protected Line$, Trimmed$, Row$, Func$, ParamNo$, Token$
  
  If ReadFile(#FileInput, FilePath$) = 0
    ProcedureReturn
  EndIf
  Format = ReadStringFormat(#FileInput)
  If Format = #PB_Ascii
    Format = #PB_UTF8
  EndIf
  
  While Eof(#FileInput) = 0
    Line$ = ReadString(#FileInput, Format)
    LineNo + 1
    Trimmed$ = LCase(Trim(Line$))
    
    If Left(Trimmed$, 11) = "compilerif "
      Active = Bool(FindString(Trimmed$, "#pb_os_windows") > 0 And FindString(Trimmed$, "<>") = 0)
    ElseIf Left(Trimmed$, 12) = "compilerelse"
      Active = Bool(Active = #False)
    ElseIf Left(Trimmed$, 13) = "compilerendif"
      Active = #True
    ElseIf Active And Left(Trimmed$, 5) = "data$"
      Line$ = Trim(Line$)
      Quote1 = FindString(Line$, Chr(34))
      If Quote1
        Quote2 = FindString(Line$, Chr(34), Quote1 + 1)
        If Quote2 > Quote1
          Row$ = Mid(Line$, Quote1 + 1, Quote2 - Quote1 - 1)
          Count = CountString(Row$, ",") + 1
          If Count >= 3
            Func$ = Trim(StringField(Row$, 1, ","))
            ParamNo$ = Trim(StringField(Row$, 2, ","))
            For I = 3 To Count
              Token$ = Trim(StringField(Row$, I, ","))
              If Left(Token$, 1) = "#"
                RegisterConstantUse(Token$, Func$, ParamNo$, LineNo)
              EndIf
            Next
          EndIf
        EndIf
      EndIf
    EndIf
  Wend
  CloseFile(#FileInput)
EndProcedure

; Wildcard entries (#PB_Shortcut_*): give their uses to every known constant with that prefix.
Procedure ApplyConstantWildcards()
  Protected Prefix$, WUsedBy$, WKeywords$
  NewList Wild.s()
  
  ForEach Consts()
    If Right(MapKey(Consts()), 1) = "*"
      AddElement(Wild())
      Wild() = MapKey(Consts())
    EndIf
  Next
  
  ForEach Wild()
    If FindMapElement(Consts(), Wild())
      WUsedBy$ = Consts()\UsedBy$
      WKeywords$ = Consts()\Keywords$
      Prefix$ = Left(Wild(), Len(Wild()) - 1)
      ForEach Consts()
        If Right(MapKey(Consts()), 1) <> "*" And Left(MapKey(Consts()), Len(Prefix$)) = Prefix$
          Consts()\UsedBy$ = MergeItems(Consts()\UsedBy$, WUsedBy$, ", ")
          Consts()\Keywords$ = MergeItems(Consts()\Keywords$, WKeywords$, "|")
        EndIf
      Next
    EndIf
  Next
EndProcedure

; Group a "Func(1), Func(2), Other(3)" list by function: "Func(1,2), Other(3)" (first appearance order).
Procedure.s GroupUsedBy(Items$)
  Protected I, Count, Pos, Item$, Func$, ParamNo$, Result$
  NewList Order.s()
  NewMap Params.s()
  
  Count = CountString(Items$, ", ") + 1
  For I = 1 To Count
    Item$ = StringField(Items$, I, ", ")
    Pos = FindString(Item$, "(")
    If Pos
      Func$ = Left(Item$, Pos - 1)
      ParamNo$ = Mid(Item$, Pos + 1, Len(Item$) - Pos - 1)
      If FindMapElement(Params(), Func$) = 0
        AddElement(Order())
        Order() = Func$
        Params(Func$) = ParamNo$
      Else
        Params(Func$) + "," + ParamNo$
      EndIf
    EndIf
  Next
  
  ForEach Order()
    If Result$ <> ""
      Result$ + ", "
    EndIf
    Result$ + Order() + "(" + Params(Order()) + ")"
  Next
  ProcedureReturn Result$
EndProcedure

; Turn the merged constants into entries of the "Constants" group.
Procedure BuildConstantEntries()
  ForEach Consts()
    LastElement(Entries())
    AddElement(Entries())
    Entries()\Kind = #KindConstant
    Entries()\Library$ = #ConstantGroup$
    Entries()\Name$ = Consts()\Name$
    Entries()\Description$ = Consts()\Description$
    If Entries()\Description$ = "" And Right(Consts()\Name$, 1) = "*"
      Entries()\Description$ = "All constants starting with " + Left(Consts()\Name$, Len(Consts()\Name$) - 1)
    EndIf
    Entries()\DefinedIn$ = ReplaceString(Consts()\DefinedIn$, "|", ", ")
    If Consts()\DefinedInMore
      Entries()\DefinedIn$ + ", ..."
    EndIf
    Entries()\UsedBy$ = GroupUsedBy(Consts()\UsedBy$)
    Entries()\Keywords$ = Consts()\Keywords$
    Entries()\RelativePath$ = Consts()\RelativePath$
    Entries()\SourceLine = Consts()\SourceLine
    ConstantCount + 1
    EntryCount + 1
  Next
EndProcedure

; ---- HTML output ------------------------------------------------------------

; Sort entries once by Library, then by Name (case insensitive).
Procedure SortDocEntries()
  ForEach Entries()
    Entries()\SortKey$ = Entries()\Library$ + #TAB$ + Entries()\Name$
  Next
  SortStructuredList(Entries(), #PB_Sort_Ascending | #PB_Sort_NoCase, OffsetOf(DocEntry\SortKey$), #PB_String)
EndProcedure

; Copy the HTML head (stored in DataSection) to the output, replacing {{INFO}}.
Procedure WriteHeadBlock(Info$)
  Protected Line$
  
  Restore HtmlHead
  Repeat
    Read.s Line$
    If Line$ <> "#END#"
      Out(ReplaceString(Line$, "{{INFO}}", Info$))
    EndIf
  Until Line$ = "#END#"
EndProcedure

; Copy the HTML tail and script (stored in DataSection) to the output.
Procedure WriteTailBlock()
  Protected Line$
  
  Restore HtmlTail
  Repeat
    Read.s Line$
    If Line$ <> "#END#"
      Out(Line$)
    EndIf
  Until Line$ = "#END#"
EndProcedure

; Keep the first MaxItems items of a ", " separated list, followed by ", ..." when it was cut.
Procedure.s CapList(List$, MaxItems)
  Protected I, Result$
  
  If CountString(List$, ", ") < MaxItems
    ProcedureReturn List$
  EndIf
  For I = 1 To MaxItems
    If I > 1
      Result$ + ", "
    EndIf
    Result$ + StringField(List$, I, ", ")
  Next
  ProcedureReturn Result$ + ", ..."
EndProcedure

; Write the generated HTML file with one collapsible group per library (entries must be sorted).
Procedure WriteHTMLIndex(FilePath$)
  Protected GitHubURL$, Cell$, Row$, Info$, CurrentGroup$ = ""
  Protected InGroup = #False
  NewMap GroupCount()
  
  If CreateFile(#FileOutput, FilePath$) = 0
    ProcedureReturn #False
  EndIf
  
  ForEach Entries()
    GroupCount(Entries()\Library$) + 1
  Next
  
  Info$ = "Generated " + FormatDate("%yyyy-%mm-%dd", Date()) + " from local PB IDE OpenSource : " + Str(EntryCount) + " entries (" + Str(FunctionCount) + " library functions, " + Str(ReferenceCount) + " reference entries, " + Str(ConstantCount) + " constants). Links target the official GitHub repository."
  WriteHeadBlock(EscapeHTML(Info$))
  
  ForEach Entries()
    If Entries()\Library$ <> CurrentGroup$
      If InGroup
        Out("</tbody></table></details>")
      EndIf
      CurrentGroup$ = Entries()\Library$
      InGroup = #True
      Out("<details class='lib-group' data-g='" + EscapeHTML(CurrentGroup$) + "' open>")
      Out("<summary>" + EscapeHTML(CurrentGroup$) + " (" + Str(GroupCount(CurrentGroup$)) + ")</summary>")
      Out("<table>")
      Out("<colgroup><col style='width:14%'><col style='width:22%'><col style='width:38%'><col style='width:26%'></colgroup>")
      If Entries()\Kind = #KindConstant
        Out("<thead><tr><th>Constant</th><th>Defined in</th><th>Description</th><th>Used by (function, parameter)</th></tr></thead><tbody>")
      Else
        Out("<thead><tr><th>Name</th><th>Syntax</th><th>Description</th><th>Return value</th></tr></thead><tbody>")
      EndIf
    EndIf
    
    GitHubURL$ = #GitHubBase$ + EncodeURLPath(Entries()\RelativePath$) + "#L" + Str(Entries()\SourceLine)
    
    ; Keywords (reference words, functions using a constant) are searchable through data-k.
    Row$ = "<tr class='entry-row'"
    If Entries()\Keywords$ <> ""
      Row$ + " data-k='" + EscapeHTML(ReplaceString(Entries()\Keywords$, "|", " ")) + "'"
    EndIf
    Out(Row$ + ">")
    
    Cell$ = "<td class='name'><a href='" + GitHubURL$ + "' target='_blank' rel='noopener'>" + EscapeHTML(Entries()\Name$) + "</a>"
    If Entries()\Chapter$ <> "" And Entries()\Chapter$ <> Entries()\Name$
      Cell$ + " <span class='chapter'>" + EscapeHTML(Entries()\Chapter$) + "</span>"
    EndIf
    Out(Cell$ + "</td>")
    
    If Entries()\Kind = #KindConstant
      Out("<td>" + EscapeHTML(Entries()\DefinedIn$) + "</td>")
      Out("<td class='description'>" + EscapeHTML(Entries()\Description$) + "</td>")
      Out("<td class='returnvalue'>" + EscapeHTML(CapList(Entries()\UsedBy$, #MaxUsedByShown)) + "</td>")
    Else
      Out("<td class='signature'><code>" + ReplaceString(EscapeHTML(Entries()\Signature$), #LF$, "<br>") + "</code></td>")
      Out("<td class='description'>" + EscapeHTML(Entries()\Description$) + "</td>")
      Out("<td class='returnvalue'>" + EscapeHTML(Entries()\ReturnValue$) + "</td>")
    EndIf
    Out("</tr>")
  Next
  
  If InGroup
    Out("</tbody></table></details>")
  EndIf
  
  WriteTailBlock()
  CloseFile(#FileOutput)
  ProcedureReturn #True
EndProcedure

; ---- JSON output (optional) ---------------------------------------------------

CompilerIf #CreateJSON
  
  ; Escape a string for JSON.
  Procedure.s EscapeJSON(Text$)
    Text$ = ReplaceString(Text$, "\", "\\")
    Text$ = ReplaceString(Text$, Chr(34), "\" + Chr(34))
    Text$ = ReplaceString(Text$, #CR$, "")
    Text$ = ReplaceString(Text$, #LF$, "\n")
    Text$ = ReplaceString(Text$, #TAB$, "\t")
    ProcedureReturn Text$
  EndProcedure
  
  ; Return ,"key":"value" or "" when the value is empty.
  Procedure.s JsonPair(Key$, Value$)
    If Value$ = ""
      ProcedureReturn ""
    EndIf
    ProcedureReturn "," + Chr(34) + Key$ + Chr(34) + ":" + Chr(34) + EscapeJSON(Value$) + Chr(34)
  EndProcedure
  
  ; Write a compact JSON copy of the index, one entry per line (entries must be sorted).
  Procedure WriteJSONIndex(FilePath$)
    Protected Row$, Type$, Legend$, Separator$ = ""
    
    If CreateFile(#FileJSON, FilePath$) = 0
      ProcedureReturn #False
    EndIf
    
    Legend$ = "t=type, g=group, n=name, s=syntax, d=description, r=return value, c=chapter, k=keywords, x=defined in, u=used by (function(parameter number)), f=source file:line relative to base"
    WriteStringN(#FileJSON, "{" + Mid(JsonPair("generated", FormatDate("%yyyy-%mm-%dd", Date())), 2) + JsonPair("base", #GitHubBase$) + JsonPair("legend", Legend$) + "," + Chr(34) + "entries" + Chr(34) + ":[", #PB_UTF8)
    
    ForEach Entries()
      Select Entries()\Kind
        Case #KindFunction
          Type$ = "function"
        Case #KindReference
          Type$ = "reference"
        Default
          Type$ = "constant"
      EndSelect
      
      Row$ = "{" + Chr(34) + "t" + Chr(34) + ":" + Chr(34) + Type$ + Chr(34)
      Row$ + JsonPair("g", Entries()\Library$) + JsonPair("n", Entries()\Name$)
      Row$ + JsonPair("s", Entries()\Signature$) + JsonPair("d", Entries()\Description$)
      Row$ + JsonPair("r", Entries()\ReturnValue$) + JsonPair("c", Entries()\Chapter$)
      If Entries()\Kind <> #KindConstant
        Row$ + JsonPair("k", ReplaceString(Entries()\Keywords$, "|", ", "))
      EndIf
      Row$ + JsonPair("x", Entries()\DefinedIn$) + JsonPair("u", Entries()\UsedBy$)
      Row$ + JsonPair("f", Entries()\RelativePath$ + ":" + Str(Entries()\SourceLine)) + "}"
      
      WriteStringN(#FileJSON, Separator$ + Row$, #PB_UTF8)
      Separator$ = ","
    Next
    
    WriteStringN(#FileJSON, "]}", #PB_UTF8)
    CloseFile(#FileJSON)
    ProcedureReturn #True
  EndProcedure
  
CompilerEndIf

;------ Main program -----
; Choose the PureBasic source root, scan the documentation and the IDE constants, save the HTML (and JSON).
Define DefaultOutput$, Message$, ConstantsPath$, JSONPath$, SelectedPath$ = "E:\PureBasic\PureBasic_Opensource\purebasic-devel_2026-10-13\"

SourceRoot$ = PathRequester("PB source", SelectedPath$)
If SourceRoot$ = "" : End : EndIf

SourceRoot$ = EnsureTrailingSlash(SourceRoot$)
EnglishPath$ = SourceRoot$ + "Documentation\English\"

If FileSize(EnglishPath$) <> -2
  MessageRequester("PureBasic Documentation Index", "Cannot find the folder:" + #CRLF$ + EnglishPath$, #PB_MessageRequester_Error)
  End
EndIf

; Collect all .txt files below Documentation\English, including Reference.
ScanDirectory(EnglishPath$)

If ListSize(Entries()) = 0
  MessageRequester("PureBasic Documentation Index", "No entries were found in:" + #CRLF$ + EnglishPath$, #PB_MessageRequester_Warning)
  End
EndIf

; Constants: documented ones are already collected; add the function parameter uses from the IDE file.
ConstantsPath$ = SourceRoot$ + ReplaceString(#ConstantsDataFile$, "/", "\")
If FileSize(ConstantsPath$) > 0
  ParseConstantsData(ConstantsPath$)
Else
  Debug "ConstantsData.pbi not found (constants come from the docs only): " + ConstantsPath$
EndIf
ApplyConstantWildcards()
BuildConstantEntries()
SortDocEntries()

; Report unknown tags to check the parser against new documentation tags.
ForEach UnknownTags()
  Debug "Unknown tag " + MapKey(UnknownTags()) + " x" + Str(UnknownTags())
Next

DefaultOutput$ = SourceRoot$ + "PureBasic_Documentation_Index.html"
OutputPath$ = SaveFileRequester("Save the HTML documentation index", DefaultOutput$, "HTML files (*.html)|*.html", 0)
If OutputPath$ = "" : End : EndIf

If GetExtensionPart(OutputPath$) = ""
  OutputPath$ + ".html"
EndIf

If WriteHTMLIndex(OutputPath$)
  Message$ = Str(EntryCount) + " entries written (" + Str(FunctionCount) + " functions, " + Str(ReferenceCount) + " reference entries, " + Str(ConstantCount) + " constants)." + #CRLF$
  Message$ + Str(SkippedPages) + " reference pages without @Syntax skipped, " + Str(MapSize(UnknownTags())) + " unknown tags (see Debug)." + #CRLF$ + #CRLF$ + OutputPath$
  
  CompilerIf #CreateJSON
    JSONPath$ = GetPathPart(OutputPath$) + GetFilePart(OutputPath$, #PB_FileSystem_NoExtension) + ".json"
    If WriteJSONIndex(JSONPath$)
      Message$ + #CRLF$ + JSONPath$
    Else
      Message$ + #CRLF$ + "Unable to write the JSON file: " + JSONPath$
    EndIf
  CompilerEndIf
  
  MessageRequester("PureBasic Documentation Index", Message$, #PB_MessageRequester_Ok)
Else
  MessageRequester("PureBasic Documentation Index", "Unable to write the output file:" + #CRLF$ + #CRLF$ + OutputPath$, #PB_MessageRequester_Error)
EndIf

End

;------ HTML template -----
; single quotes only, so no escaping is needed
DataSection
  HtmlHead:
  Data.s "<!doctype html>"
  Data.s "<html lang='en'>"
  Data.s "<head>"
  Data.s "<meta charset='utf-8'>"
  Data.s "<meta name='viewport' content='width=device-width, initial-scale=1'>"
  Data.s "<title>PureBasic Documentation Index</title>"
  Data.s "<link rel='icon' href='data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 64 64%27%3E%3Cdefs%3E%3CclipPath"
  Data.s " id=%27c%27%3E%3Cpath d=%27M25 2 17 14 28 17 24 22 16 22 10 31 15 34 5 47 37 59 49 48 20 39 24 35 34 37 44 26 34 24 53 4Z%27/%3E%3C/clipPath%3E%3C/defs%3E%3Cpath"
  Data.s " d=%27M25 2 17 14 28 17 24 22 16 22 10 31 15 34 5 47 37 59 49 48 20 39 24 35 34 37 44 26 34 24 53 4Z%27 transform=%27translate(5 3)%27 opacity=%27.25%27/%3E%3Cg"
  Data.s " transform=%27translate(3 1)%27%3E%3Cpath d=%27M25 2 17 14 28 17 24 22 16 22 10 31 15 34 5 47 37 59 49 48 20 39 24 35 34 37 44 26 34 24 53 4Z%27 fill=%27%231f65c0%27"
  Data.s " stroke=%27%2308357a%27 stroke-width=%274%27 stroke-linejoin=%27round%27/%3E%3Cpath d=%27M25 2 17 14 28 17 24 22 16 22 10 31 15 34 5 47 37 59 49 48 20 39 24 35 34 37 44 26 34 24 53 4Z%27"
  Data.s " fill=%27none%27 stroke=%27%235b9fe8%27 stroke-width=%273%27 clip-path=%27url(%23c)%27/%3E%3C/g%3E%3C/svg%3E'>"
  Data.s "<style>"
  Data.s "body{font:15px/1.45 system-ui,Segoe UI,Arial,sans-serif;margin:12px auto;padding:0 18px;max-width:1800px;color:#202124;background:#fff}"
  Data.s "h1{font-size:1.7rem;margin-bottom:.25em} .note{color:#666;font-size:0.95em;margin:0 0 10px}"
  Data.s ".hint{color:#666;font-size:.85em;margin:0 0 10px}"
  Data.s ".controls{display:flex;gap:10px;flex-wrap:wrap;margin:0 0 12px;padding:2px 0;align-items:center;position:sticky;top:0;background:#fff;z-index:2}"
  Data.s "input,button{font:inherit;padding:8px 12px;border:1px solid #aaa;border-radius:5px;background:#fcfcfc}"
  Data.s "button{cursor:pointer} button:hover{background:#f0f0f0}"
  Data.s "#search{flex:1;min-width:260px}"
  Data.s "details{margin-bottom:12px;border:1px solid #d0d7de;border-radius:6px;background:#fff;overflow:hidden}"
  Data.s "summary{font-weight:bold;padding:10px 14px;background:#f6f8fa;cursor:pointer;user-select:none}"
  Data.s "summary:hover{background:#eaeef2}"
  Data.s "table{border-collapse:collapse;width:100%;table-layout:fixed}"
  Data.s "th,td{text-align:left;vertical-align:top;padding:9px;border-bottom:1px solid #eee;overflow-wrap:anywhere}"
  Data.s "td.description,td.returnvalue{font-size:.9em}"
  Data.s "th{background:#fafafa;font-size:.9em;color:#444}"
  Data.s "code{white-space:pre-wrap;font-family:Consolas,monospace;font-size:.95em}"
  Data.s ".chapter{display:block;color:#666;font-size:.8em}"
  Data.s ".chips{display:flex;flex-wrap:wrap;gap:4px;margin:0 0 10px}"
  Data.s ".chip{padding:0 7px;border-radius:11px;font-size:.72em;line-height:1.6}"
  Data.s ".chip.on{background:#0759b5;color:#fff;border-color:#0759b5}"
  Data.s ".chip.zero{opacity:.4}"
  Data.s ".chip small{margin-left:3px;opacity:.75}"
  Data.s "a{color:#0759b5;text-decoration:none} a:hover{text-decoration:underline}"
  Data.s "</style>"
  Data.s "</head><body>"
  Data.s "<h1>PureBasic Documentation Index</h1>"
  Data.s "<p class='note'>{{INFO}}</p>"
  Data.s "<div class='controls'>"
  Data.s "<input id='search' type='search' placeholder='Search name, keyword or description...' autofocus>"
  Data.s "<button type='button' id='btnToggle'>Expand / Collapse All</button>"
  Data.s "<span id='count' aria-live='polite'></span>"
  Data.s "</div>"
  Data.s "<p class='hint'>All words must match &middot; <b>&quot;exact words&quot;</b> &middot; <b>lib:gadget</b> library filter &middot; <b>ref:</b> references only &middot; <b>const:</b> constants only (e.g. <b>const:window</b>) &middot; ranked: exact name, name starts with, name contains, then keywords and descriptions.<br>Click the library chips to restrict the search (several allowed).</p>"
  Data.s "<div id='chips' class='chips'></div>"
  Data.s "<div id='container'>"
  Data.s "#END#"
  
  HtmlTail:
  Data.s "</div>"
  Data.s "<script>"
  Data.s "const search=document.getElementById('search'), count=document.getElementById('count'), btn=document.getElementById('btnToggle'), box=document.getElementById('container');"
  Data.s "const groups=[...document.querySelectorAll('.lib-group')];"
  Data.s "function norm(s){return s.toLowerCase().replace(/[-:_]+/g,' ').replace(/\s+/g,' ').trim();}"
  Data.s "function esc(s){return s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');}"
  Data.s "// Normalized texts are computed once: name, chapter, keywords, description."
  Data.s "groups.forEach((g,gi)=>{"
  Data.s "  g._i=gi; g._name=norm(g.dataset.g); g._body=g.querySelector('tbody'); g._rows=[...g.querySelectorAll('tr.entry-row')];"
  Data.s "  g._rows.forEach((r,ri)=>{"
  Data.s "    const ch=r.cells[0].querySelector('.chapter');"
  Data.s "    r._i=ri; r._n=norm(r.cells[0].querySelector('a').textContent); r._c=ch?norm(ch.textContent):'';"
  Data.s "    r._k=norm(r.dataset.k||''); r._d=norm(r.cells[2].textContent); r._h=r._n+' '+r._c+' '+r._k+' '+r._d;"
  Data.s "  });"
  Data.s "});"
  Data.s "// Library chips: Reference and Constants first, then the libraries. Empty selection = all."
  Data.s "const chipBox=document.getElementById('chips'), sel=new Set();"
  Data.s "const allChip=document.createElement('button'); allChip.type='button'; allChip.className='chip on'; allChip.textContent='All'; chipBox.appendChild(allChip);"
  Data.s "allChip.addEventListener('click',()=>{sel.clear(); filterRows();});"
  Data.s "const rank=n=>n==='Reference'?0:n==='Constants'?1:2;"
  Data.s "[...groups].sort((a,b)=>rank(a.dataset.g)-rank(b.dataset.g)||a._i-b._i).forEach(g=>{"
  Data.s "  const b=document.createElement('button'), sm=document.createElement('small');"
  Data.s "  b.type='button'; b.className='chip'; b.append(g.dataset.g, sm); g._chip=b; g._sm=sm;"
  Data.s "  b.addEventListener('click',()=>{if(sel.has(g._i))sel.delete(g._i); else sel.add(g._i); filterRows();});"
  Data.s "  chipBox.appendChild(b);"
  Data.s "});"
  Data.s "// Query: words (all must match), quoted exact words, lib:name, ref:, const:."
  Data.s "function parseQuery(v){"
  Data.s "  const q={words:[],phrases:[],libs:[]};"
  Data.s "  (v.match(/\x22[^\x22]*\x22|\S+/g)||[]).forEach(t=>{"
  Data.s "    if(t[0]==='\x22'){const p=norm(t.replace(/\x22/g,'')); if(p)q.phrases.push(new RegExp('(?<![a-z0-9#])'+esc(p)+'(?![a-z0-9])'));return;}"
  Data.s "    const m=/^(lib|ref|const):(.*)$/i.exec(t);"
  Data.s "    if(m){const k=m[1].toLowerCase(), w=norm(m[2]);"
  Data.s "      if(k==='lib'){if(w)q.libs.push(w);} else {q.libs.push(k==='ref'?'reference':'constants'); if(w)q.words.push(w);}"
  Data.s "      return;}"
  Data.s "    const w=norm(t); if(w)q.words.push(w);"
  Data.s "  });"
  Data.s "  return q;"
  Data.s "}"
  Data.s "function match(r,q){return q.words.every(w=>r._h.includes(w))&&q.phrases.every(p=>p.test(r._h));}"
  Data.s "// Ranking: exact name 1000, name starts with 800, name contains 600, all words in name 500, name/keywords 300, description 100."
  Data.s "function score(r,q){"
  Data.s "  const f=q.words.join(' '), n=r._n; let s=100;"
  Data.s "  if(f){"
  Data.s "    if(n===f)s=1000; else if(n.startsWith(f))s=800; else if(n.includes(f))s=600;"
  Data.s "    else if(q.words.every(w=>n.includes(w)))s=500;"
  Data.s "    else if(q.words.every(w=>(n+' '+r._c+' '+r._k).includes(w)))s=300;"
  Data.s "  }"
  Data.s "  if(q.phrases.length&&q.phrases.every(p=>p.test(n)))s=Math.max(s,700);"
  Data.s "  return s;"
  Data.s "}"
  Data.s "let expanded=true, timer=0;"
  Data.s "btn.addEventListener('click',()=>{expanded=!expanded;groups.forEach(g=>g.open=expanded);});"
  Data.s "function filterRows(){"
  Data.s "  const q=parseQuery(search.value), active=q.words.length||q.phrases.length||q.libs.length||sel.size;"
  Data.s "  let total=0, shown=0;"
  Data.s "  groups.forEach(g=>{"
  Data.s "    const gl=!q.libs.length||q.libs.some(l=>g._name.includes(l)), so=!sel.size||sel.has(g._i), vis=[]; let best=0, n0=0;"
  Data.s "    g._rows.forEach(r=>{"
  Data.s "      total++;"
  Data.s "      const m=gl&&match(r,q), ok=m&&so; if(m)n0++;"
  Data.s "      r.style.display=ok?'':'none';"
  Data.s "      if(ok){r._s=score(r,q)-(g._name==='constants'?20:0); if(r._s>best)best=r._s; vis.push(r);}"
  Data.s "    });"
  Data.s "    g._best=best; shown+=vis.length;"
  Data.s "    g._sm.textContent=(q.words.length||q.phrases.length||q.libs.length)?n0:g._rows.length; g._chip.classList.toggle('on',sel.has(g._i)); g._chip.classList.toggle('zero',!!(q.words.length||q.phrases.length||q.libs.length)&&!n0);"
  Data.s "    g.style.display=vis.length?'':'none';"
  Data.s "    if(active&&vis.length)g.open=true;"
  Data.s "    if(active){vis.sort((a,b)=>b._s-a._s||a._i-b._i); vis.forEach(r=>g._body.appendChild(r)); g._dirty=true;}"
  Data.s "    else if(g._dirty){g._rows.forEach(r=>g._body.appendChild(r)); g._dirty=false;}"
  Data.s "  });"
  Data.s "  if(active||box._dirty){"
  Data.s "    [...groups].sort(active?(a,b)=>b._best-a._best||a._i-b._i:(a,b)=>a._i-b._i).forEach(g=>box.appendChild(g));"
  Data.s "    box._dirty=!!active;"
  Data.s "  }"
  Data.s "  allChip.classList.toggle('on',!sel.size); count.textContent=shown+' / '+total+' entries';"
  Data.s "}"
  Data.s "search.addEventListener('input',()=>{clearTimeout(timer); timer=setTimeout(filterRows,120);});"
  Data.s "filterRows();"
  Data.s "</script>"
  Data.s "</body></html>"
  Data.s "#END#"
EndDataSection

; IDE Options = PureBasic 6.41 (Windows - x64)
; CursorPosition = 1187
; FirstLine = 1175
; Folding = -------
; EnableXP
; DPIAware